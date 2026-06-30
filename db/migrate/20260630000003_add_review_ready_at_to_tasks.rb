class AddReviewReadyAtToTasks < ActiveRecord::Migration[8.0]
  def up
    add_column :tasks, :review_ready_at, :datetime
    # Backfill existing in_review items so their order is stable immediately.
    execute "UPDATE tasks SET review_ready_at = COALESCE(finished_at, updated_at) WHERE board_state = 'in_review'"
  end

  def down
    remove_column :tasks, :review_ready_at
  end
end
