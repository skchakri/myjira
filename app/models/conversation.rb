# One Claude CLI session, captured turn-by-turn. The transcript on disk
# (~/.claude/projects/<encoded-cwd>/<session>.jsonl) is the source; a Stop hook
# parses new lines after every turn and POSTs them to /api/v1/conversations/sync,
# which folds them into this record. One Conversation per CLI sessionId.
class Conversation < ApplicationRecord
  belongs_to :project
  has_many :conversation_messages, -> { order(:position, :occurred_at) }, dependent: :destroy
  # Relay tickets this CLI session filed (linked by cli_session_id). nullify on
  # destroy so closing a conversation never deletes relay history.
  has_many :browser_tasks, dependent: :nullify
  # Commands sent from the web to this (live) session, picked up by the listener.
  has_many :session_commands, dependent: :destroy

  validates :session_id, presence: true, uniqueness: true

  # A relay can be filed before this session's transcript is captured. When the
  # conversation finally lands, adopt any orphan relays that named this session.
  after_create_commit :adopt_orphan_browser_tasks

  scope :recent, -> { order(Arel.sql("COALESCE(last_message_at, created_at) DESC")) }

  # "Live" = synced a turn very recently. The Stop hook updates last_message_at
  # at the end of each turn, so this tracks sessions active in the last few min.
  LIVE_WINDOW = 8.minutes
  scope :live, -> { where("COALESCE(last_message_at, created_at) > ?", LIVE_WINDOW.ago) }

  def live?
    (last_message_at || created_at) > LIVE_WINDOW.ago
  end

  # Title comes from Claude's own ai-title when present; otherwise fall back to
  # the opening user prompt, then a short session label.
  def display_title
    return name if name.present?
    return title if title.present?
    first = conversation_messages.where(role: "user").order(:position).first
    return first.body.to_s.split("\n").first.to_s.truncate(80) if first
    "Session #{session_id.first(8)}"
  end

  # Recompute the denormalised rollup after a sync batch.
  def refresh_counts!
    update_columns(
      message_count: conversation_messages.count,
      last_message_at: conversation_messages.maximum(:occurred_at) || last_message_at || created_at
    )
  end

  private

  def adopt_orphan_browser_tasks
    BrowserTask.where(cli_session_id: session_id, conversation_id: nil)
               .update_all(conversation_id: id)
  end
end
