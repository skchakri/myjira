class CreateBrowserTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :browser_tasks, id: :uuid do |t|
      t.uuid    :project_id, null: false
      t.string  :title, null: false
      t.text    :instructions
      t.string  :target_url
      t.string  :status, null: false, default: "queued"
      t.string  :priority, default: "normal"
      t.string  :source, default: "claude-cli"
      t.string  :initiated_by
      t.datetime :last_activity_at
      t.timestamps
    end

    add_index :browser_tasks, :project_id
    add_index :browser_tasks, :status
    add_index :browser_tasks, :last_activity_at
    add_foreign_key :browser_tasks, :projects
  end
end
