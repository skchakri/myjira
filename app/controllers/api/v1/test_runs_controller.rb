module Api
  module V1
    class TestRunsController < BaseController
      before_action :find_project!, only: [:index, :create]
      before_action :find_plan!,    only: [:index, :create]

      def index
        render json: @plan.test_runs.order(started_at: :desc).map { |r| serialize(r) }
      end

      def show
        run = TestRun.find(params[:id])
        render json: serialize(run, detailed: true)
      end

      def create
        run = @plan.test_runs.new(run_params)
        run.environment ||= @project.environments.find_by(id: params[:environment_id]) if params[:environment_id]
        run.save!
        render json: serialize(run, detailed: true).merge(next_steps: next_steps_for(run)), status: :created
      end

      def update
        run = TestRun.find(params[:id])
        run.update!(run_params)
        render json: serialize(run, detailed: true)
      end

      def complete
        run = TestRun.find(params[:id])
        run.summary = params[:summary] if params[:summary]
        run.completed_at = Time.current
        run.status = derive_status(run)
        run.save!
        render json: serialize(run, detailed: true)
      end

      private

      def find_plan!
        @plan = @project.test_plans.find(params[:test_plan_id])
      end

      def run_params
        raw = params[:test_run] || params
        raw.permit(:initiated_by, :summary, :environment_id, :status)
      end

      def derive_status(run)
        run.recalc_counts!
        return "failed"   if run.failed_count.to_i.positive?
        return "partial"  if run.blocked_count.to_i.positive? || run.skipped_count.to_i.positive?
        return "passed"   if run.passed_count.to_i == run.total_cases.to_i && run.total_cases.to_i.positive?
        "partial"
      end

      def serialize(run, detailed: false)
        data = {
          id: run.id, status: run.status, progress: run.progress,
          started_at: run.started_at, completed_at: run.completed_at,
          initiated_by: run.initiated_by,
          counts: { total: run.total_cases, passed: run.passed_count, failed: run.failed_count,
                    blocked: run.blocked_count, skipped: run.skipped_count },
          urls: {
            web: "#{base_url}/test_runs/#{run.id}",
            api: "#{base_url}/api/v1/test_runs/#{run.id}"
          }
        }
        if detailed
          data[:summary] = run.summary
          data[:results] = run.test_results.includes(:test_case).map do |r|
            { id: r.id, test_case_id: r.test_case_id, position: r.test_case.position,
              title: r.test_case.title, status: r.status,
              actual_result: r.actual_result, notes: r.notes, screenshot_url: r.screenshot_url,
              update_url: "#{base_url}/api/v1/test_runs/#{run.id}/results/#{r.test_case_id}" }
          end.sort_by { |x| x[:position] }
        end
        data
      end
    end
  end
end
