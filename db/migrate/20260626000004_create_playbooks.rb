# A Playbook is a saved, reusable run recipe: a prompt/steps body plus explicit
# success criteria and guardrails, optionally bound to an Agent and/or Project.
# It can be triggered (→ a SessionLaunch) or scheduled (→ an AgentSchedule), and
# every fire records a PlaybookRun so the playbook accrues pass/fail history.
class CreatePlaybooks < ActiveRecord::Migration[8.1]
  def change
    create_table :playbooks, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :name, null: false
      t.references :project, type: :uuid, null: true, foreign_key: true, index: true
      t.references :agent, type: :uuid, null: true, foreign_key: true, index: true
      t.text :body, null: false
      t.text :success_criteria
      t.text :guardrails
      t.string :model
      t.string :permission_mode
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end
  end
end
