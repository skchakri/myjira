class TestRun < ApplicationRecord
  STATUSES = %w[running passed failed partial aborted].freeze

  belongs_to :test_plan
  belongs_to :environment, optional: true
  has_many :test_results, dependent: :destroy

  validates :status, inclusion: { in: STATUSES }

  before_create :set_started_at
  after_create :seed_results
  after_update :propagate_status_to_tasks, if: :saved_change_to_status?
  after_update_commit :broadcast_header, if: -> { saved_change_to_status? || saved_change_to_passed_count? || saved_change_to_failed_count? || saved_change_to_blocked_count? || saved_change_to_skipped_count? }

  def broadcast_header
    broadcast_replace_to [self, :results],
      target: "run_header_#{id}",
      partial: "test_runs/header",
      locals: { run: self }
  end

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

  # When a run finishes, move attached tasks forward. Only touches tasks that
  # were in a non-terminal state so we don't undo a manual "done"/"blocked".
  def propagate_status_to_tasks
    target =
      case status
      when "passed"          then "done"
      when "failed"          then "blocked"
      when "partial"         then "testing"
      when "running"         then "testing"
      end
    return unless target

    movable = %w[open in_progress implemented ready_for_test testing]
    movable << "blocked" if status == "passed" # recovery path

    test_plan.tasks.where(status: movable).find_each do |task|
      task.update!(status: target)
    end
  end

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
