# Ties a "Run in Chrome" launch to its Work Queue item ("<queue-slug>:<n>") so a
# live session blocks a second launch for the same item, and records when the
# session reported it finished and when the daemon saw its tmux window close.
class AddWorkItemKeyToSessionLaunches < ActiveRecord::Migration[8.0]
  def change
    add_column :session_launches, :work_item_key, :string
    add_column :session_launches, :finished_at, :datetime
    add_column :session_launches, :closed_at, :datetime
    add_index :session_launches, [:work_item_key, :status]
  end
end
