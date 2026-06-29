class AddAutoTriageToProjects < ActiveRecord::Migration[8.0]
  def change
    add_column :projects, :auto_triage_enabled, :boolean, default: false, null: false
  end
end
