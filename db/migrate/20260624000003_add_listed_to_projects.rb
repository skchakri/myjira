# Explicit "show in the Clients sidebar/index" flag. The clients scope normally
# only surfaces projects that have real work, so the conversation-capture hook's
# per-directory junk stays hidden. `listed` lets a project be pinned into the
# sidebar on purpose — e.g. client checkouts imported deliberately — even before
# it has any task/plan. Default false preserves existing behaviour.
class AddListedToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :listed, :boolean, default: false, null: false
    add_index :projects, :listed
  end
end
