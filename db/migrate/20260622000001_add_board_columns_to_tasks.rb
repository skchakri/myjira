# Project Board, Phase 0. Extends Task into a board item: a type (task/feature/
# issue/ask), a board workflow state (the 8-state machine), an explicit priority
# `position` (drag to reorder), the agent role chosen by the planning agent, the
# implementation plan, PR linkage (captured by the agent so the container needs no
# gh creds), and pointers to the latest session/test-run. Legacy `status` is kept
# and `board_state` is backfilled from it so nothing in the old views breaks.
class AddBoardColumnsToTasks < ActiveRecord::Migration[8.1]
  STATUS_TO_BOARD = {
    "open" => "pending",
    "in_progress" => "in_progress",
    "implemented" => "in_progress",
    "ready_for_test" => "in_progress",
    "testing" => "in_progress",
    "done" => "done",
    "blocked" => "failed"
  }.freeze

  def up
    add_column :tasks, :item_type,   :string,  null: false, default: "task"
    add_column :tasks, :board_state, :string,  null: false, default: "pending"
    add_column :tasks, :position,    :integer
    add_column :tasks, :agent_role,  :string,  null: false, default: "unassigned"
    add_column :tasks, :plan,            :text
    add_column :tasks, :plan_updated_at, :datetime
    add_column :tasks, :branch_name,     :string
    add_column :tasks, :pr_url,          :string
    add_column :tasks, :pr_number,       :integer
    add_column :tasks, :pr_state,        :string
    add_column :tasks, :pr_diff,         :text
    add_column :tasks, :pr_synced_at,    :datetime
    add_column :tasks, :last_conversation_id, :uuid
    add_column :tasks, :last_test_run_id,     :uuid
    add_column :tasks, :agent_notes,        :text
    add_column :tasks, :picked_up_at,       :datetime
    add_column :tasks, :finished_at,        :datetime
    add_column :tasks, :autopilot_attempts, :integer, null: false, default: 0

    add_index :tasks, [:project_id, :position]
    add_index :tasks, [:project_id, :board_state]
    add_index :tasks, :item_type
    add_index :tasks, :last_conversation_id
    add_index :tasks, :last_test_run_id

    say_with_time "backfilling board_state + position from legacy status" do
      Task.reset_column_information
      Task.group(:project_id).pluck(:project_id).each do |project_id|
        Task.where(project_id: project_id).order(:created_at).each_with_index do |task, i|
          board = STATUS_TO_BOARD[task.status] || "pending"
          task.update_columns(board_state: board, position: i + 1) # rubocop:disable Rails/SkipsModelValidations
        end
      end
    end
  end

  def down
    remove_index :tasks, [:project_id, :position]
    remove_index :tasks, [:project_id, :board_state]
    remove_index :tasks, :item_type
    remove_index :tasks, :last_conversation_id
    remove_index :tasks, :last_test_run_id
    %i[item_type board_state position agent_role plan plan_updated_at branch_name
       pr_url pr_number pr_state pr_diff pr_synced_at last_conversation_id
       last_test_run_id agent_notes picked_up_at finished_at autopilot_attempts].each do |col|
      remove_column :tasks, col
    end
  end
end
