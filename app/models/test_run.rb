class TestRun < ApplicationRecord
  STATUSES = %w[running passed failed partial aborted].freeze

  belongs_to :test_plan
  belongs_to :environment, optional: true
  has_many :test_results, dependent: :destroy

  validates :status, inclusion: { in: STATUSES }

  before_create :set_started_at
  after_create :seed_results

  def progress
    total = total_cases.to_i
    done = passed_count.to_i + failed_count.to_i + blocked_count.to_i + skipped_count.to_i
    { total: total, done: done, percent: total.zero? ? 0 : (done * 100.0 / total).round(1) }
  end

  def recalc_counts!
    self.total_cases = test_plan.test_cases.count
    self.passed_count  = test_results.where(status: "pass").count
    self.failed_count  = test_results.where(status: "fail").count
    self.blocked_count = test_results.where(status: "blocked").count
    self.skipped_count = test_results.where(status: "skipped").count
    save!
  end

  private

  def set_started_at
    self.started_at ||= Time.current
  end

  def seed_results
    test_plan.test_cases.find_each do |tc|
      test_results.create!(test_case: tc, status: "pending")
    end
    recalc_counts!
  end
end
