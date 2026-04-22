# Walks every pending TestResult in a TestRun and executes its TestCase's
# api_call server-side against the run's Environment base_url. Pushes each
# result back via normal model updates so Turbo Stream broadcasts fire, and
# completes the run at the end.
class RunExecutorJob < ApplicationJob
  queue_as :default

  def perform(run_id)
    run = TestRun.find(run_id)
    return if run.completed_at.present?

    project = run.test_plan.project
    env = run.environment
    base_url = env&.base_url.presence || project.default_base_url

    run.update!(initiated_by: run.initiated_by.presence || "myjira-auto")

    pending = run.test_results.where(status: "pending").includes(:test_case).order("test_cases.position").references(:test_case)
    pending.find_each do |result|
      parsed = ApiCallParser.parse(result.test_case.api_call, base_url: base_url)
      outcome = ApiCallExecutor.run(parsed)
      result.update!(
        status: outcome[:status],
        actual_result: outcome[:actual_result],
        notes: outcome[:notes]
      )
    end

    run.reload.recalc_counts!
    run.completed_at = Time.current
    run.status = derive_run_status(run)
    run.summary = build_summary(run)
    run.save!
  end

  private

  def derive_run_status(run)
    if run.failed_count.to_i.positive?
      "failed"
    elsif run.blocked_count.to_i.positive? || run.skipped_count.to_i.positive?
      "partial"
    elsif run.passed_count.to_i == run.total_cases.to_i && run.total_cases.to_i.positive?
      "passed"
    else
      "partial"
    end
  end

  def build_summary(run)
    "Auto-executed by myjira · #{run.passed_count} passed / #{run.failed_count} failed / #{run.blocked_count} blocked / #{run.skipped_count} skipped out of #{run.total_cases}"
  end
end
