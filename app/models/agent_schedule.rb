require "fugit"

# A recurring trigger: run a prompt (optionally an Agent) in a project's repo on
# a cron. myjira owns the schedule and the cron math; the host launcher daemon
# ticks AgentSchedule.due each loop and calls #fire!, which files a SessionLaunch
# (spawned by the daemon's existing pending-poll) and rolls next_run_at forward.
class AgentSchedule < ApplicationRecord
  belongs_to :project
  belongs_to :agent, optional: true
  belongs_to :last_launch, class_name: "SessionLaunch", optional: true

  validates :prompt, presence: true
  validates :cron, presence: true
  validate  :cron_must_parse
  validates :model, inclusion: { in: SessionLaunch::MODELS }, allow_blank: true
  validates :permission_mode, inclusion: { in: SessionLaunch::PERMISSION_MODES }, allow_blank: true

  before_validation :derive_prompt_from_agent, on: :create
  before_save :recompute_next_run, if: :should_recompute_next_run?

  scope :recent,  -> { order(created_at: :desc) }
  scope :enabled, -> { where(enabled: true) }
  # Ready to fire: enabled and its next occurrence has passed.
  scope :due, -> { enabled.where.not(next_run_at: nil).where(next_run_at: ..Time.current) }

  # The parsed cron (Fugit::Cron), or nil when the expression is invalid.
  def fugit
    return @fugit if defined?(@fugit)
    @fugit = (Fugit.parse_cron(cron) if cron.present?)
  end

  # Next fire time strictly after `from`, as a Time (nil if the cron is invalid).
  def next_occurrence(from = Time.current)
    fugit&.next_time(from)&.to_t
  end

  # Queue a launch in the project's repo and roll next_run_at forward. Returns
  # the SessionLaunch, or nil when the project has no known repo path (in which
  # case we still advance next_run_at so a repo-less schedule doesn't hot-loop).
  # Raises if the launch itself can't be queued — the tick wraps each schedule so
  # one failure is recorded (see #note_failure!) without aborting the batch.
  def fire!(now: Time.current)
    launch =
      if project.repo_path.present?
        SessionLaunch.queue!(
          project: project,
          prompt: prompt,
          model: model.presence || "default",
          permission_mode: permission_mode.presence || "default",
          agent: agent,
          title: schedule_title,
          source: "scheduled"
        )
      end
    update!(
      last_launch: launch || last_launch,
      last_run_at: now,
      next_run_at: next_occurrence(now),
      last_status: launch ? "ok" : "skipped",
      last_error: launch ? nil : "Project has no repo_path — nothing to launch.",
      consecutive_failures: launch ? 0 : consecutive_failures
    )
    launch
  end

  # Record a failed fire and still roll next_run_at forward, so a persistently
  # broken schedule retries at its next scheduled time instead of hot-looping
  # every daemon tick (and never blocks sibling schedules). update_columns skips
  # validations/callbacks — we're recovering from an error, not re-saving.
  def note_failure!(error, now: Time.current)
    update_columns(
      last_status: "failed",
      last_error: error.to_s.truncate(500),
      last_failed_at: now,
      consecutive_failures: consecutive_failures.to_i + 1,
      next_run_at: next_occurrence(now),
      updated_at: now
    )
  end

  private

  # An agent-based schedule can be created with just agent + task; build the
  # prompt the same way a one-off trigger would.
  def derive_prompt_from_agent
    self.prompt = agent.launch_prompt(task) if prompt.blank? && agent
  end

  def should_recompute_next_run?
    will_save_change_to_cron? || (enabled? && next_run_at.nil?)
  end

  def recompute_next_run
    self.next_run_at = next_occurrence(Time.current)
  end

  def cron_must_parse
    return if cron.blank?
    errors.add(:cron, %(is not a valid cron expression (try "0 9 * * *"))) if fugit.nil?
  end

  def schedule_title
    base = agent ? "#{agent.glyph} #{agent.name}" : prompt
    "⏱ #{base}".truncate(80)
  end
end
