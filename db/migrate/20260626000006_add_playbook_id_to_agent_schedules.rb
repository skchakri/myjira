# Lets a schedule know it's driving a playbook: when set, AgentSchedule#fire!
# records a PlaybookRun alongside the launch it already queues.
class AddPlaybookIdToAgentSchedules < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_schedules, :playbook_id, :uuid
    add_index :agent_schedules, :playbook_id
  end
end
