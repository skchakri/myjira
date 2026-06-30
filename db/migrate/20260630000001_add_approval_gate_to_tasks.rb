class AddApprovalGateToTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :tasks, :wait_reason, :string
    add_column :tasks, :pending_questions, :jsonb, null: false, default: []
    add_column :tasks, :plan_version, :integer, null: false, default: 1
  end
end
