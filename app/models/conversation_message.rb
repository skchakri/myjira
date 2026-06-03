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
