class Task < ApplicationRecord
  # Legacy lifecycle (kept for the older task views + test-run propagation).
  STATUSES = %w[open in_progress implemented ready_for_test testing done blocked].freeze
  PRIORITIES = %w[low normal high urgent].freeze

  # --- Project Board ---------------------------------------------------------
  # What kind of work this is. issue = bug, feature = improvement, ask = question.
  ITEM_TYPES = %w[task feature issue ask].freeze
  # The board workflow. pending is the default a new item lands in; the planning
  # agent moves it to planned; an engineering/debugger agent works it (in_progress)
  # then opens a PR (in_review) or fails its tests (failed). waiting = needs input
  # from the human; hold = human parked it. done is terminal.
  BOARD_STATES = %w[pending planned in_progress waiting hold in_review failed done].freeze
  # Which agent works the item, decided by the planning agent. answer_only handles
  # "ask" questions with a written answer and no PR.
  AGENT_ROLES = %w[unassigned engineering debugger answer_only].freeze

  # States the autopilot orchestrator may pick up (a first-come-first-out queue).
  ACTIONABLE_STATES = %w[pending planned failed].freeze
  # After this many failed autopilot attempts the item is parked for a human
  # (moved to waiting) instead of burning the daily cap on one broken item.
  MAX_AUTOPILOT_ATTEMPTS = 2

  # Attachment guards for the rich board-item composer. The web create form has
  # no auth, so bound count and per-file size here. Type is intentionally open
  # ("files, images, video, and everything") — capped by size/count, not kind.
  MAX_ATTACHMENTS     = 20
  MAX_ATTACHMENT_SIZE = 100.megabytes

  ITEM_TYPE_GLYPHS = { "task" => "✔", "feature" => "✦", "issue" => "🐛", "ask" => "?" }.freeze
  BOARD_STATE_LABELS = {
    "pending" => "Pending", "planned" => "Planned", "in_progress" => "In progress",
    "waiting" => "Waiting", "hold" => "On hold", "in_review" => "In review",
    "failed" => "Failed", "done" => "Done"
  }.freeze
  # Ordered groups for the board (Kanban columns / collapsible table sections).
  BOARD_GROUP_ORDER = %w[in_progress planned pending waiting hold in_review failed done].freeze

  belongs_to :project
  belongs_to :environment, optional: true
  belongs_to :last_conversation, class_name: "Conversation", optional: true
  belongs_to :last_test_run, class_name: "TestRun", optional: true

  has_many :test_plan_tasks, dependent: :destroy
  has_many :test_plans, through: :test_plan_tasks
  has_many :test_cases, dependent: :nullify
  has_many :follow_up_tasks, dependent: :destroy
  has_many :session_launches, dependent: :nullify

  # Rich context the author (or an agent) attaches to a board item: reference
  # screenshots, screen recordings, audio notes, PDFs, logs — anything that
  # explains the work. Surfaced on the item page and counted on the board row.
  has_many_attached :attachments

  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :priority, inclusion: { in: PRIORITIES }, allow_blank: true
  validates :item_type,   inclusion: { in: ITEM_TYPES }
  validates :board_state, inclusion: { in: BOARD_STATES }
  validates :agent_role,  inclusion: { in: AGENT_ROLES }
  validate :attachments_within_limits

  before_create :assign_position

  scope :recent, -> { order(created_at: :desc) }
  # Priority order: lowest position first (top of the queue), oldest as tiebreak.
  scope :board_ordered, -> { order(Arel.sql("position ASC NULLS LAST"), :created_at) }
  scope :actionable, -> { where(board_state: ACTIONABLE_STATES) }
  scope :on_board, -> { where.not(board_state: "done") }

  after_update_commit :broadcast_board, if: :saved_change_to_board_state?

  def glyph
    ITEM_TYPE_GLYPHS[item_type] || "•"
  end

  # Is there enough dumped context for a triage agent to analyse and title this?
  def has_context?
    description.present? || attachments.attached?
  end

  def board_state_label
    BOARD_STATE_LABELS[board_state] || board_state.to_s.humanize
  end

  def actionable?
    ACTIONABLE_STATES.include?(board_state)
  end

  def done?
    board_state == "done"
  end

  def pr?
    pr_url.present?
  end

  def has_plan?
    plan.present?
  end

  # The Tests column / "Run test cases" button only lights up once an agent has
  # actually built something (the item has been worked at least once).
  def tests_enabled?
    finished_at.present? || %w[in_progress in_review failed done].include?(board_state)
  end

  # The conversation to open for "see the full session".
  def session_conversation
    last_conversation || session_launches.order(created_at: :desc).filter_map(&:conversation).first
  end

  def latest_test_plan
    test_plans.order(created_at: :desc).first
  end

  # Convenience transitions used by the agent API + board UI. They assign and
  # save; callers may also just PATCH attributes directly.
  def mark_planned!(role:, plan: nil)
    self.plan = plan if plan.present?
    self.plan_updated_at = Time.current if plan.present?
    self.agent_role = role if role.present?
    update!(board_state: "planned")
  end

  def mark_in_progress!
    update!(board_state: "in_progress", picked_up_at: picked_up_at || Time.current)
  end

  def mark_in_review!(pr_url: nil, pr_number: nil, pr_state: "open", branch_name: nil, pr_diff: nil)
    assign_attributes(
      pr_url: pr_url.presence || self.pr_url,
      pr_number: pr_number.presence || self.pr_number,
      pr_state: pr_state.presence || self.pr_state,
      branch_name: branch_name.presence || self.branch_name,
      pr_diff: pr_diff.presence || self.pr_diff,
      pr_synced_at: Time.current,
      finished_at: finished_at || Time.current
    )
    update!(board_state: "in_review")
  end

  def mark_failed!(note: nil)
    self.agent_notes = note if note.present?
    self.autopilot_attempts = autopilot_attempts.to_i + 1
    update!(board_state: "failed")
  end

  def mark_done!
    update!(board_state: "done", finished_at: finished_at || Time.current)
  end

  def autopilot_exhausted?
    autopilot_attempts.to_i >= MAX_AUTOPILOT_ATTEMPTS
  end

  private

  def attachments_within_limits
    return unless attachments.attached?

    attached = attachments.attachments
    errors.add(:attachments, "too many files (max #{MAX_ATTACHMENTS})") if attached.size > MAX_ATTACHMENTS
    attached.each do |a|
      next if a.byte_size.to_i <= MAX_ATTACHMENT_SIZE
      errors.add(:attachments, "#{a.filename} exceeds #{MAX_ATTACHMENT_SIZE / 1.megabyte} MB")
    end
  end

  # New items append to the bottom of the project's priority queue.
  def assign_position
    return if position.present?
    self.position = (project&.tasks&.maximum(:position) || 0) + 1
  end

  def broadcast_board
    broadcast_refresh_to [project, :board]
  rescue StandardError => e
    Rails.logger.warn("[board] broadcast failed: #{e.message}")
  end
end
