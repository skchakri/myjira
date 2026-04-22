module ClientOverview
  extend ActiveSupport::Concern

  SEVERITY_RANK = { "critical" => 0, "high" => 1, "medium" => 2, "low" => 3 }.freeze
  OPEN_GAP_STATUSES = %w[open in_progress].freeze

  def find_or_provision_project(slug)
    Project.find_by(slug: slug) || Project.create!(
      slug: slug,
      name: slug.to_s.tr("-_", " ").split.map(&:capitalize).join(" "),
      description: "Auto-provisioned via /c/#{slug}."
    )
  end

  def build_client_overview(project)
    plans = project.test_plans.includes(:test_cases, :tasks).order(created_at: :desc)
    latest_by_plan = plans.index_with { |p| p.latest_run }
    all_results = aggregate_results(latest_by_plan.values.compact)

    gaps = project.follow_up_tasks
      .where(status: OPEN_GAP_STATUSES)
      .includes(:task, :test_result)
      .to_a
      .sort_by { |g| [ SEVERITY_RANK.fetch(g.severity, 9), -g.created_at.to_i ] }

    {
      project: project,
      plans: plans,
      latest_runs: latest_by_plan,
      open_gaps: gaps,
      stats: {
        plans: plans.size,
        active_plans: plans.count { |p| p.status == "active" },
        runs_total: TestRun.where(test_plan_id: plans.map(&:id)).count,
        passed:  all_results[:pass].to_i,
        failed:  all_results[:fail].to_i,
        blocked: all_results[:blocked].to_i,
        skipped: all_results[:skipped].to_i,
        open_gaps: gaps.size,
        critical_gaps: gaps.count { |g| %w[critical high].include?(g.severity) }
      }
    }
  end

  private

  def aggregate_results(runs)
    {
      pass:    runs.sum { |r| r.passed_count.to_i },
      fail:    runs.sum { |r| r.failed_count.to_i },
      blocked: runs.sum { |r| r.blocked_count.to_i },
      skipped: runs.sum { |r| r.skipped_count.to_i }
    }
  end
end
