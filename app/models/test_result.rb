class TestResult < ApplicationRecord
  STATUSES = %w[pending pass fail blocked skipped].freeze

  belongs_to :test_run
  belongs_to :test_case
  has_many :follow_up_tasks, dependent: :nullify

  validates :status, inclusion: { in: STATUSES }

  after_update :bump_run, if: :saved_change_to_status?

  private

  def bump_run
    self.completed_at ||= Time.current if %w[pass fail blocked skipped].include?(status)
    save! if completed_at_changed?
    test_run.recalc_counts!
  end
end
