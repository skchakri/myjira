# One turn in a BrowserTask thread. role says who spoke; kind classifies the
# turn so the status machine (BrowserTask#advance_for!) and the UI can react.
class BrowserMessage < ApplicationRecord
  ROLES = %w[cli browser user system].freeze
  KINDS = %w[message instruction question answer result done error note].freeze

  belongs_to :browser_task

  validates :role, inclusion: { in: ROLES }
  validates :kind, inclusion: { in: KINDS }
  validates :body, presence: true

  after_create_commit :advance_task_and_broadcast

  def display_role
    { "cli" => "Claude CLI", "browser" => "Claude · Chrome", "user" => "You", "system" => "myjira" }[role] || role.humanize
  end

  private

  def advance_task_and_broadcast
    browser_task.advance_for!(self)

    broadcast_append_to [browser_task, :messages],
      target: "messages_#{browser_task.id}",
      partial: "browser_messages/message",
      locals: { message: self }

    broadcast_replace_to [browser_task, :messages],
      target: "browser_task_header_#{browser_task.id}",
      partial: "browser_tasks/header",
      locals: { task: browser_task }
  end
end
