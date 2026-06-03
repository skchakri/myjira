# A command the user sends from the web to a *live* CLI session. The session,
# while running the `myjira-listen` listener, polls for pending commands, runs
# them, and posts a result back. Only works while the session is live and
# listening — myjira can't push into a running terminal.
class SessionCommand < ApplicationRecord
  STATUSES = %w[pending running done failed].freeze

  belongs_to :conversation

  validates :body, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }
  scope :pending, -> { where(status: "pending") }

  after_create_commit :broadcast_new
  after_update_commit :broadcast_update

  def done?
    %w[done failed].include?(status)
  end

  private

  def broadcast_new
    broadcast_prepend_to [conversation, :commands],
      target: "session_commands_#{conversation_id}",
      partial: "session_commands/command", locals: { command: self }
  end

  def broadcast_update
    broadcast_replace_to [conversation, :commands],
      target: "session_command_#{id}",
      partial: "session_commands/command", locals: { command: self }
  end
end
