class TestResult < ApplicationRecord
  include Searchable

  STATUSES = %w[pending pass fail blocked skipped].freeze

  belongs_to :test_run
  belongs_to :test_case
  has_many :follow_up_tasks, dependent: :nullify

  validates :status, inclusion: { in: STATUSES }

  after_update :bump_run, if: :saved_change_to_status?

  after_update_commit :broadcast_row, if: :saved_change_to_status?

  def broadcast_row
    broadcast_replace_to [test_run, :results],
      target: "result_#{id}",
      partial: "test_runs/result_row",
      locals: { r: self }
  end

  private

  def bump_run
    self.completed_at ||= Time.current if %w[pass fail blocked skipped].include?(status)
    save! if completed_at_changed?
    test_run.recalc_counts!
  end
end
