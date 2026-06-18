# One turn-fragment in a Conversation: a user prompt, a chunk of Claude's reply,
# or a single tool action (a Bash command, a file edit, …). role + kind drive
# the chat bubble in the UI. ext_id is the producer's stable, dedup key.
class ConversationMessage < ApplicationRecord
  ROLES = %w[user assistant system].freeze
  KINDS = %w[message tool].freeze

  belongs_to :conversation

  validates :ext_id, presence: true
  validates :role, inclusion: { in: ROLES }
  validates :kind, inclusion: { in: KINDS }

  after_create_commit :broadcast_to_thread

  def display_role
    { "user" => "You", "assistant" => "Claude", "system" => "myjira" }[role] || role.humanize
  end

  # For kind == "tool", the tool name lives in payload — used to pick an icon.
  def tool_name
    payload.is_a?(Hash) ? payload["tool"] : nil
  end

  # Document-ish files (reports, plans, exports) — not source code, so a Write
  # to one of these reads as "Claude produced a document you'd want to open".
  DOCUMENT_EXTENSIONS = %w[
    .md .markdown .mdx .txt .rst .adoc .html .htm .pdf .csv .tsv .docx .xlsx .pptx
  ].freeze

  # Absolute path of a document this turn created via Write, or nil. Drives the
  # clickable link in the transcript and the "Documents" card on the show page.
  def document_path
    return nil unless kind == "tool" && tool_name == "Write"
    path = payload.dig("input", "file_path").to_s
    path if path.start_with?("/") && DOCUMENT_EXTENSIONS.include?(File.extname(path).downcase)
  end

  private

  # Live-append new turns to anyone watching the conversation (mirrors the
  # browser_task relay thread).
  def broadcast_to_thread
    broadcast_append_to [conversation, :messages],
      target: "messages_#{conversation.id}",
      partial: "conversation_messages/message",
      locals: { message: self }
  end
end
