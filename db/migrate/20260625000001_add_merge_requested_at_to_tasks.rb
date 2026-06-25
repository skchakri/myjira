# When a human clicks "Approve & merge" on an in_review board item, we stamp
# merge_requested_at and let the host daemon do the actual `gh pr merge` (the
# Rails container has no GitHub access). The daemon clears it once the PR is
# merged (→ done) or the merge fails (→ note, stays in_review).
class AddMergeRequestedAtToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :merge_requested_at, :datetime
    add_index :tasks, :merge_requested_at
  end
end
