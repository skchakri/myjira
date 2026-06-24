# Project Board, Phase 0. Tie a launch (and the conversation it spawns) to the
# board item it is working, and record which pipeline step it is so the board can
# show "planning…/engineering…" and the orchestrator can reason about in-flight work.
class AddBoardColumnsToSessionLaunches < ActiveRecord::Migration[8.1]
  def change
    add_column :session_launches, :task_id, :uuid
    add_column :session_launches, :pipeline_step, :string

    add_index :session_launches, :task_id
    add_foreign_key :session_launches, :tasks, on_delete: :nullify
  end
end
