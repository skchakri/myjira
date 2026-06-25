# Soft "archive" state for a project. Archiving keeps the project and all its
# work intact (board, tasks, history) but hides it from the sidebar nav and the
# default projects index — a way to retire finished/dormant folders without
# deleting them. Nullable timestamp records *when* it was archived; nil = active.
class AddArchivedAtToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :archived_at, :datetime
    add_index :projects, :archived_at
  end
end
