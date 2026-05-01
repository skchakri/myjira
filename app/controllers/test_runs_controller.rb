class TestRunsController < ApplicationController
  def show
    @run = TestRun.find(params[:id])
    @plan = @run.test_plan
    @project = @plan.project
    @results = @run.test_results.includes(:test_case).to_a.sort_by { |r| r.test_case.position }
  end

  def new
    set_project_and_plan
    @run = @plan.test_runs.new
  end

  def create
    set_project_and_plan
    @run = @plan.test_runs.new(environment_id: params.dig(:test_run, :environment_id), initiated_by: params.dig(:test_run, :initiated_by))
    if @run.save
      redirect_to test_run_path(@run), notice: "Run started with #{@run.total_cases} cases."
    else
      render :new, status: :unprocessable_entity
    end
  end

  # Kick off server-side execution of every pending case in a run.
  # Works for any case whose api_call is a real HTTP request; prose/browser
  # instructions are automatically marked blocked by the executor.
  def execute
    @run = TestRun.find(params[:id])
    if @run.completed_at.present?
      redirect_to test_run_path(@run), alert: "Run already completed."
      return
    end
    RunExecutorJob.perform_later(@run.id)
    redirect_to test_run_path(@run), notice: "Running #{@run.total_cases} cases server-side — this page updates live."
  end

  # Spawn the local Playwright + Claude CLI runner for browser-style cases.
  # Background job shells out to `node script/playwright_runner/index.js` so
  # the user does not have to keep a terminal open.
  def playwright_execute
    @run = TestRun.find(params[:id])
    if @run.completed_at.present?
      redirect_to test_run_path(@run), alert: "Run already completed."
      return
    end
    pending = @run.test_results.where(status: "pending").count
    PlaywrightRunnerJob.perform_later(@run.id, request.base_url)
    redirect_to test_run_path(@run), notice: "Playwright AI runner launched on #{pending} cases — results stream in below."
  end

  def complete
    @run = TestRun.find(params[:id])
    @run.summary = params[:summary]
    @run.completed_at = Time.current
    @run.recalc_counts!
    @run.status = if @run.failed_count.to_i.positive?
                    "failed"
                  elsif @run.blocked_count.to_i.positive? || @run.skipped_count.to_i.positive?
                    "partial"
                  elsif @run.passed_count.to_i == @run.total_cases.to_i && @run.total_cases.to_i.positive?
                    "passed"
                  else
                    "partial"
                  end
    @run.save!
    redirect_to test_run_path(@run), notice: "Run completed."
  end

  private

  def set_project_and_plan
    @project = Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
    @plan = @project.test_plans.find(params[:test_plan_id])
  end
end
