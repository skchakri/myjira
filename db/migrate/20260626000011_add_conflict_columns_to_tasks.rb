class AddConflictColumnsToTasks < ActiveRecord::Migration[8.1]
  def change
    # gh's mergeable enum for the PR vs. base: MERGEABLE / CONFLICTING / UNKNOWN.
    # Derived during the existing 5-min pr_sync poll; only CONFLICTING is actionable.
    add_column :tasks, :pr_mergeable, :string
    # Set when a resolve-conflicts agent session is queued, so the board shows a
    # spinner and the button can't double-fire while resolution is in flight.
    add_column :tasks, :conflict_resolution_at, :datetime
  end
end
