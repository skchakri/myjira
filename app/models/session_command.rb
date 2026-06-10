# A command the user sends from the web to a *live* CLI session. The session,
# while running the `myjira-listen` listener, polls for pending commands, runs
# them, and posts a result back. Only works while the session is live and
# listening — myjira can't push into a running terminal.
class SessionCommand < ApplicationRecord
  STATUSES = %w[pending running done failed].freeze

  # Attachment guards. The upload endpoint has no auth and the listener
  # auto-downloads these to the host, so bound count / size / type here —
  # the browser `accept=` filter is advisory only.
  MAX_FILES         = 10
  MAX_FILE_SIZE     = 25.megabytes
  ALLOWED_FILE_TYPE = %r{\A(image|video|audio)/}

  belongs_to :conversation
  # Files the user attached to drive the session — images / video / audio,
  # like dropping a file into Claude CLI. The listener downloads them.
  has_many_attached :files

  validates :body, presence: true, unless: -> { files.attached? }
  validates :status, inclusion: { in: STATUSES }
  validate :files_within_limits

  scope :recent, -> { order(created_at: :desc) }
  scope :pending, -> { where(status: "pending") }

  after_create_commit :broadcast_new
  after_update_commit :broadcast_update

  def done?
    %w[done failed].include?(status)
  end

  private

  def files_within_limits
    return unless files.attached?

    attached = files.attachments
    errors.add(:files, "too many files (max #{MAX_FILES})") if attached.size > MAX_FILES
    attached.each do |a|
      errors.add(:files, "#{a.filename} exceeds #{MAX_FILE_SIZE / 1.megabyte} MB") if a.byte_size.to_i > MAX_FILE_SIZE
      errors.add(:files, "#{a.filename} is not an image, video, or audio file") unless a.content_type.to_s.match?(ALLOWED_FILE_TYPE)
    end
  end

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
