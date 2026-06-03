class AddNameToConversations < ActiveRecord::Migration[8.1]
  def change
    # User-set session name (overrides the auto title); shown in the web UI and,
    # via the statusline script, in the CLI itself.
    add_column :conversations, :name, :string
  end
end
