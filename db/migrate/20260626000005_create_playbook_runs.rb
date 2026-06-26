# One execution of a Playbook. Links to the SessionLaunch it spawned (and, for a
# scheduled fire, the AgentSchedule that drove it). Its `result` records whether
# the run met the playbook's success criteria — conceptually distinct from the
# launch's spawn-outcome (did `claude` get off the ground), so it lives here.
class CreatePlaybookRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :playbook_runs, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :playbook, type: :uuid, null: false, foreign_key: true, index: true
      t.references :session_launch, type: :uuid, null: true, foreign_key: true, index: true
      t.uuid :agent_schedule_id, null: true
      t.string :result, null: false, default: "pending"
      t.datetime :evaluated_at
      t.text :notes
      t.timestamps
    end
    add_index :playbook_runs, :agent_schedule_id
  end
end
