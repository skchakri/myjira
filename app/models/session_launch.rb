# A web-filed request to start a *new* interactive Claude CLI session in a
# project's repo. myjira can't reach into the host to run `claude` itself (the
# Rails app is containerised), so a host-side daemon — myjira_session_launcher.py
# — polls `pending`, spawns `claude` in a tmux window inside repo_path, and
# PATCHes status back. The launched session is told to use our pre-generated
# session_id (`claude --session-id`), so the conversation captured by the sync
# hook folds into the placeholder Conversation we create up front — it appears in
# the grid the instant you click Launch and fills in live as the session runs.
class SessionLaunch < ApplicationRecord
  STATUSES = %w[pending launching launched failed canceled].freeze
  # "default" → omit the flag and let the CLI pick. Kept short and shell-safe;
  # the daemon re-validates before interpolating into the tmux command.
  MODELS           = %w[default opus sonnet haiku].freeze
  PERMISSION_MODES = %w[default acceptEdits plan bypassPermissions].freeze
  # Which board pipeline step this launch is (nil for plain "＋ New session"s).
  # triage = the lightweight "you dumped context, I'll assign title/type/priority" pass.
  PIPELINE_STEPS   = %w[triage review planning engineering debugger answer].freeze

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

  scope :recent,  -> { order(created_at: :desc) }
  scope :pending, -> { where(status: "pending") }
  # What the "active launches" strip shows: still in flight, or launched recently
  # enough that the attach hint is still useful (before the live convo takes over).
  scope :active, lambda {
    where(status: %w[pending launching])
      .or(where(status: "launched").where(launched_at: 12.minutes.ago..))
  }

  # Queue a launch in `project`'s repo and pre-create the placeholder
  # Conversation it binds to (so it shows in the grid the instant it's queued and
  # fills in live once the daemon spawns `claude --session-id`). Single path for
  # the "＋ New session" button, agent triggers, and scheduled fires.
  def self.queue!(project:, prompt:, model: "default", permission_mode: "default",
                  agent: nil, title: nil, source: "launched", task: nil, pipeline_step: nil)
    transaction do
      launch = project.session_launches.create!(
        prompt: prompt, model: model, permission_mode: permission_mode, agent: agent,
        task: task, pipeline_step: pipeline_step
      )
      convo = project.conversations.create!(
        session_id: launch.session_id,
        source: source,
        title: (title.presence || prompt.split("\n").map(&:strip).find(&:present?).to_s).truncate(80),
        cwd: project.repo_path,
        started_at: Time.current,
        last_message_at: Time.current
      )
      launch.update!(conversation: convo)
      # Link the conversation to the board item so its Session column opens this
      # thread the instant the step is queued (it fills in live as the agent runs).
      task&.update_columns(last_conversation_id: convo.id, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      launch
    end
  end

  def done?
    %w[launched failed canceled].include?(status)
  end

  # The --model value, or nil when "default" (let the CLI decide).
  def model_flag
    model.present? && model != "default" ? model : nil
  end

  # The --permission-mode value, or nil when "default" (interactive prompts).
  def permission_mode_flag
    permission_mode.present? && permission_mode != "default" ? permission_mode : nil
  end

  # "tmux attach -t myjira" + the window — shown so the user can take the session
  # over. tmux_target is "session:window"; surface the session for the attach cmd.
  def tmux_session
    tmux_target.to_s.split(":").first.presence
  end

  private

  def assign_session_id
    self.session_id ||= SecureRandom.uuid
  end

  def inherit_repo_path
    self.repo_path ||= project&.repo_path
  end
end
