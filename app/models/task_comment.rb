# A single append-only note on a board item (Task). author is "you" for notes
# added from the web, or a role/name for notes posted by an agent via the API.
class TaskComment < ApplicationRecord
  belongs_to :task

  validates :body, presence: true
end
