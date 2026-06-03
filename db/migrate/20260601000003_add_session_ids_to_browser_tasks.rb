class AddSessionIdsToBrowserTasks < ActiveRecord::Migration[8.1]
  def change
    # Which CLI session filed this relay, and which Chrome session handled it.
    add_column :browser_tasks, :cli_session_id, :string
    add_column :browser_tasks, :browser_session_id, :string
    add_reference :browser_tasks, :conversation, type: :uuid, null: true, foreign_key: true

    add_index :browser_tasks, :cli_session_id
    add_index :browser_tasks, :browser_session_id
  end
end
