class ResetTaskPositions < ActiveRecord::Migration[8.1]
  # Legacy drags stamped a global position (1..N) across every status group, so the
  # recency default never applied anywhere after the first drag. Now that `position`
  # is set only by genuine, per-group drags, clear the old global pollution so every
  # group returns to processing-recency order. A human re-establishes any pins they
  # want the next time they drag. up-only; there's nothing meaningful to restore.
  def up
    Task.update_all(position: nil) # rubocop:disable Rails/SkipsModelValidations
  end

  def down
    # no-op: the legacy global ordering is intentionally not restorable
  end
end
