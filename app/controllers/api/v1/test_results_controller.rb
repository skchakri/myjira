module Api
  module V1
    class TestResultsController < BaseController
      before_action :find_run!

      def index
        render json: @run.test_results.includes(:test_case).map { |r| serialize(r) }
      end

      # PATCH /api/v1/test_runs/:test_run_id/results/:id
      # :id is the test_case_id (easier for clients that only know case IDs)
      def update
        result = @run.test_results.find_by(test_case_id: params[:id]) ||
                 @run.test_results.find(params[:id])
        result.update!(result_params)
        render json: serialize(result)
      end

      private

      def find_run!
        @run = TestRun.find(params[:test_run_id])
      end

      def result_params
        raw = params[:test_result] || params
        raw.permit(:status, :actual_result, :notes, :screenshot_url)
      end

      def serialize(r)
        { id: r.id, test_case_id: r.test_case_id, status: r.status,
          actual_result: r.actual_result, notes: r.notes, screenshot_url: r.screenshot_url,
          completed_at: r.completed_at, run_progress: r.test_run.progress }
      end
    end
  end
end
