# A BrowserTask is one unit of work handed from a Claude CLI session to
# Claude-in-Chrome (the browser extension), mediated by myjira. It is a small
# chat channel: the CLI posts instructions, the user "kicks it off", the browser
# executes them in Chrome and posts results — or questions — back to the same
# ticket. Both sides watch the same thread (see #messages_since / long-poll in
# the API controller).
class BrowserTask < ApplicationRecord
  # queued       — created by the CLI, not yet released to the browser
  # dispatched   — user kicked it off; waiting for the browser to pick it up
  # in_progress  — the browser acknowledged and is working
  # needs_input  — the browser asked a question; waiting on the CLI/user
  # responded    — the browser finished and posted its result; CLI should read
  # done         — acknowledged/closed by the CLI or user
  # failed       — the browser could not complete it
  # cancelled    — abandoned before completion
  STATUSES = %w[queued dispatched in_progress needs_input responded done failed cancelled].freeze
  OPEN_STATUSES = %w[queued dispatched in_progress needs_input responded].freeze
  PRIORITIES = %w[low normal high urgent].freeze

  belongs_to :project
  # The CLI session that filed this relay (matched by cli_session_id). Optional —
  # the conversation may not be captured yet, or the id may be absent.
  belongs_to :conversation, optional: true
  has_many :browser_messages, -> { order(:created_at) }, dependent: :destroy

  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :priority, inclusion: { in: PRIORITIES }, allow_blank: true

  before_validation :ensure_last_activity, on: :create
  before_save :link_conversation

  scope :recent, -> { order(Arel.sql("COALESCE(last_activity_at, created_at) DESC")) }
  scope :open, -> { where(status: OPEN_STATUSES) }
  # Tickets the browser should act on next (something to do, nothing pending on the CLI).
  scope :for_browser, -> { where(status: %w[dispatched in_progress]) }
  # Tickets the CLI should act on next (a fresh answer or a question to address).
  scope :for_cli, -> { where(status: %w[needs_input responded]) }

  # Drives the status machine from a newly-posted message. Returns the task.
  # Called by BrowserMessage after_create so both transports stay in sync without
  # either side having to PATCH status explicitly.
  def advance_for!(message)
    new_status =
      case message.role
      when "browser"
        case message.kind
        when "question"        then "needs_input"
        when "result", "done"  then "responded"
        when "error"           then "failed"
        else status == "dispatched" ? "in_progress" : status
        end
      when "cli", "user"
        # The CLI/user answered or added context — hand the ball back to the browser.
        %w[needs_input responded].include?(status) ? "in_progress" : status
      end
    touch_activity!(new_status)
  end

  def touch_activity!(new_status = nil)
    self.last_activity_at = Time.current
    self.status = new_status if new_status.present? && new_status != status
    save!
    self
  end

  def open?
    OPEN_STATUSES.include?(status)
  end

  def waiting_on_cli?
    %w[needs_input responded].include?(status)
  end

  def waiting_on_browser?
    %w[dispatched in_progress].include?(status)
  end

  private

  def ensure_last_activity
    self.last_activity_at ||= Time.current
  end

  # Resolve cli_session_id → the captured CLI Conversation (if it exists yet).
  # Runs whenever the session id is set/changed and we don't already have a link.
  def link_conversation
    return if conversation_id.present? || cli_session_id.blank?
    self.conversation = Conversation.find_by(session_id: cli_session_id)
  end
end
