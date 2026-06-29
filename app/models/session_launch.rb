# A web-filed request to start a *new* interactive Claude CLI session in a
# project's repo. myjira can't reach into the host to run `claude` itself (the
# Rails app is containerised), so a host-side daemon — myjira_session_launcher.py
# — polls `pending`, spawns `claude` in a tmux window inside repo_path, and
# PATCHes status back. The launched session is told to use our pre-generated
# session_id (`claude --session-id`), so the conversation captured by the sync
# hook folds into the placeholder Conversation we create up front — it appears in
# the grid the instant you click Launch and fills in live as the session runs.
class SessionLaunch < ApplicationRecord
  include Worklogged

  # canceling = the budget enforcer flagged an over-cap run for the daemon's kill
  # leg; the daemon `tmux kill-session`s it and PATCHes status → canceled.
  STATUSES = %w[pending launching launched failed canceled canceling].freeze
  # "default" → omit the flag and let the CLI pick. Kept short and shell-safe;
  # the daemon re-validates before interpolating into the tmux command.
  MODELS           = %w[default opus sonnet haiku].freeze
  PERMISSION_MODES = %w[default acceptEdits plan bypassPermissions].freeze
  # Which board pipeline step this launch is (nil for plain "＋ New session"s).
  # triage = the lightweight "you dumped context, I'll assign title/type/priority" pass.
  PIPELINE_STEPS   = %w[triage review planning engineering debugger answer resolve_conflicts].freeze
  # Derived spawn-outcomes the launcher metrics roll up. This reflects whether
  # `claude` got off the ground, not whether the work it then did succeeded (the
  # bound Conversation could refine that later) — a faithful first cut, no column.
  OUTCOMES         = %w[succeeded failed cancelled running].freeze
  # How long after launched_at a "launched" row still counts as in flight — the
  # same window the `active` scope uses to keep the attach hint useful. Shared by
  # the scope and #outcome so the two can never drift apart.
  ACTIVE_LAUNCHED_WINDOW = 12.minutes

  belongs_to :project
  belongs_to :conversation, optional: true
  # Set when this launch came from clicking an agent in the project's strip.
  belongs_to :agent, optional: true
  # Set when this launch is a board pipeline step working a specific item.
  belongs_to :task, optional: true

  before_validation :assign_session_id, on: :create
  before_validation :inherit_repo_path, on: :create

  validates :session_id, presence: true, uniqueness: true
  validates :prompt, presence: true
  validates :repo_path, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :model, inclusion: { in: MODELS }, allow_blank: true
  validates :permission_mode, inclusion: { in: PERMISSION_MODES }, allow_blank: true
  validates :pipeline_step, inclusion: { in: PIPELINE_STEPS }, allow_blank: true

  # One timeline node per real status transition (the daemon claims a row before
  # spawning, so it walks pending → launching → launched). Guarded on the change
  # so a re-PATCH of the same status can't dupe a node.
  after_update_commit :emit_status_worklog, if: :saved_change_to_status?

  scope :recent,  -> { order(created_at: :desc) }
  scope :pending, -> { where(status: "pending") }
  # What the "active launches" strip shows: still in flight, or launched recently
  # enough that the attach hint is still useful (before the live convo takes over).
  scope :active, lambda {
    where(status: %w[pending launching])
      .or(where(status: "launched").where(launched_at: ACTIVE_LAUNCHED_WINDOW.ago..))
  }

  # An ad-hoc launch fired FROM a board item just reached a terminal status →
  # append a one-line result to that item. Board pipeline steps are excluded
  # (their agents PATCH their own structured result), and the guard fires only on
  # the *transition into* a terminal status so repeated daemon PATCHes can't dupe.
  after_update_commit :record_task_result, if: :should_record_task_result?

  # Queue a launch in `project`'s repo and pre-create the placeholder
  # Conversation it binds to (so it shows in the grid the instant it's queued and
  # fills in live once the daemon spawns `claude --session-id`). Single path for
  # the "＋ New session" button, agent triggers, and scheduled fires.
  # Coarse launch-time turn backstop for pipeline launches, from MYJIRA_MAX_TURNS
  # (0/blank → no flag). The $ cap below is the real enforcement; this just bounds
  # how far a runaway can overshoot between cost syncs.
  DEFAULT_BOARD_MAX_TURNS = ENV.fetch("MYJIRA_MAX_TURNS", "0").to_i

  def self.queue!(project:, prompt:, model: "default", permission_mode: "default",
                  agent: nil, title: nil, source: "launched", task: nil, pipeline_step: nil,
                  budget_cap_cents: nil, max_turns: nil)
    # Pipeline (board/playbook) launches inherit a per-run $ cap + turn backstop so
    # an unattended runaway is bounded; ad-hoc "＋ New session" launches stay uncapped
    # unless a cap is passed explicitly.
    if pipeline_step.present?
      budget_cap_cents ||= project.autopilot_budget_cap_cents
      max_turns        ||= DEFAULT_BOARD_MAX_TURNS
    end
    transaction do
      # Derive the conversation title from the RAW user prompt first, then fold
      # the project memory block (static preamble + learned facts) onto the front
      # of the stored prompt the daemon spawns verbatim. This is the single
      # chokepoint for the "＋ New session" button, agent triggers, board pipeline
      # steps, and scheduled fires, so every launch carries the memory. Empty
      # memory → prompt is unchanged (no separator, no blank block).
      convo_title = (title.presence || prompt.split("\n").map(&:strip).find(&:present?).to_s).truncate(80)
      memory = project.memory_block
      spawn_prompt = memory.present? ? "#{memory}\n\n---\n\n#{prompt}" : prompt

      launch = project.session_launches.create!(
        prompt: spawn_prompt, model: model, permission_mode: permission_mode, agent: agent,
        task: task, pipeline_step: pipeline_step,
        budget_cap_cents: budget_cap_cents,
        max_turns: (max_turns.to_i.positive? ? max_turns.to_i : nil)
      )
      convo = project.conversations.create!(
        session_id: launch.session_id,
        source: source,
        title: convo_title,
        cwd: project.repo_path,
        started_at: Time.current,
        last_message_at: Time.current
      )
      launch.update!(conversation: convo)
      # Link the conversation to the board item so its Session column opens this
      # thread the instant the step is queued (it fills in live as the agent runs).
      task&.update_columns(last_conversation_id: convo.id, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      step = launch.pipeline_step.presence || "session"
      launch.emit_worklog("launch.queued", status: "running", label: "Queued #{step} in #{project.name}")
      launch
    end
  end

  def done?
    %w[launched failed canceled].include?(status)
  end

  # Map a (status, launched_at) pair to one of OUTCOMES. A "launched" row is
  # still `running` until it falls past ACTIVE_LAUNCHED_WINDOW, then it counts as
  # `succeeded` (spawned and no longer in flight). Pure, so Agent.metrics_for can
  # call it on plucked tuples without instantiating rows.
  def self.outcome_for(status, launched_at)
    case status
    when "failed"   then "failed"
    when "canceled" then "cancelled"
    when "launched"
      launched_at && launched_at > ACTIVE_LAUNCHED_WINDOW.ago ? "running" : "succeeded"
    else "running" # pending / launching
    end
  end

  # succeeded/failed/cancelled/running for this launch — see OUTCOMES.
  def outcome
    self.class.outcome_for(status, launched_at)
  end

  # The --model value, or nil when "default" (let the CLI decide).
  def model_flag
    model.present? && model != "default" ? model : nil
  end

  # The --permission-mode value, or nil when "default" (interactive prompts).
  def permission_mode_flag
    permission_mode.present? && permission_mode != "default" ? permission_mode : nil
  end

  # The --max-turns value the daemon interpolates, or nil when unset (no flag).
  def max_turns_flag
    max_turns.to_i.positive? ? max_turns : nil
  end

  # "tmux attach -t myjira" + the window — shown so the user can take the session
  # over. tmux_target is "session:window"; surface the session for the attach cmd.
  def tmux_session
    tmux_target.to_s.split(":").first.presence
  end

  # URL to a ttyd instance so the user can watch (or drive) this session live
  # in the browser. Requires MYJIRA_TTYD_HOST / MYJIRA_TTYD_PORT env vars (or
  # defaults localhost:7681). Returns nil when there is no tmux_target yet.
  def live_terminal_url
    return nil if tmux_target.blank?

    host = ENV.fetch("MYJIRA_TTYD_HOST", "localhost")
    port = ENV.fetch("MYJIRA_TTYD_PORT", "7681")
    "http://#{host}:#{port}/?arg=attach&arg=-t&arg=#{CGI.escape(tmux_target)}"
  end

  private

  # Map a status flip onto a worklog node. "launched" stays a running step (the
  # spawned `claude` is still working); there's no terminal node for it — it ages
  # out of the strip and the timeline becomes the durable worklog.
  def emit_status_worklog
    case status
    when "launching"
      emit_worklog("launch.claiming", status: "running", label: "Host daemon claimed the launch")
    when "launched"
      emit_worklog("launch.spawned", status: "running",
        label: tmux_target.present? ? "Spawned claude · #{tmux_target}" : "Spawned claude",
        payload: { tmux_target: tmux_target })
    when "failed"
      emit_worklog("launch.failed", status: "failed", label: error.presence || "Launch failed")
    when "canceling"
      emit_worklog("launch.canceling", status: "waiting", label: "Killing session (over budget)")
    when "canceled"
      emit_worklog("launch.canceled", status: "info", label: "Canceled")
    end
  end

  # Fire only when this update flipped status into a terminal value (so a daemon
  # re-PATCHing the same terminal status can't duplicate the comment), and only
  # for a task-bound, non-pipeline launch.
  def should_record_task_result?
    saved_change_to_status? && done? && task_id.present? && pipeline_step.blank? &&
      !%w[launched failed canceled].include?(status_previously_was)
  end

  def record_task_result
    task.record_agent_result(self)
  end

  def assign_session_id
    self.session_id ||= SecureRandom.uuid
  end

  def inherit_repo_path
    self.repo_path ||= project&.repo_path
  end
end
