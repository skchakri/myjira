class CreateCalendarJobs < ActiveRecord::Migration[8.0]
  def change
    create_table :calendar_jobs, id: :uuid do |t|
      t.string   :source, null: false
      t.string   :external_id, null: false
      t.string   :title, null: false
      t.text     :command
      t.string   :cron
      t.string   :schedule_label
      t.datetime :next_run_at
      t.datetime :last_run_at
      t.boolean  :enabled, null: false, default: true
      t.uuid     :project_id
      t.uuid     :agent_schedule_id
      t.text     :evidence
      t.jsonb    :meta, null: false, default: {}
      t.datetime :synced_at
      t.datetime :dismissed_at
      t.timestamps
    end
    add_index :calendar_jobs, [:source, :external_id], unique: true
    add_index :calendar_jobs, :project_id
    add_foreign_key :calendar_jobs, :projects, on_delete: :nullify
    add_foreign_key :calendar_jobs, :agent_schedules, on_delete: :nullify
  end
end
