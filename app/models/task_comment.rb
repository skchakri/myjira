# A single append-only note on a board item (Task). author is "you" for notes
# added from the web, or a role/name for notes posted by an agent via the API.
class TaskComment < ApplicationRecord
  belongs_to :task

  validates :body, presence: true

  # New worklog entries appear live on the item page (Activity & decisions log).
  after_create_commit :broadcast_activity

  private

  def broadcast_activity
    broadcast_refresh_to [task, :activity]
  rescue StandardError => e
    Rails.logger.warn("[board] comment broadcast failed: #{e.message}")
  end
end
