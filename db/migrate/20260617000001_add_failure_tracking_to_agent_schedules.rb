class AddFailureTrackingToAgentSchedules < ActiveRecord::Migration[8.1]
  def change
    # Outcome of the last fire: "ok", "failed", or "skipped" (e.g. no repo_path).
    add_column :agent_schedules, :last_status, :string
    # Human-readable reason the last fire failed/was skipped (nil once it succeeds).
    add_column :agent_schedules, :last_error, :text
    add_column :agent_schedules, :last_failed_at, :datetime
    # Streak of consecutive failed fires; reset to 0 on a clean run.
    add_column :agent_schedules, :consecutive_failures, :integer, default: 0, null: false
  end
end
