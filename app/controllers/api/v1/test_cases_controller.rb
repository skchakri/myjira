module Api
  module V1
    class TestCasesController < BaseController
      before_action :find_project!
      before_action :find_plan!

      def index
        render json: @plan.test_cases.order(:position).map { |c| serialize(c) }
      end

      def create
        tc = @plan.test_cases.new(case_params)
        tc.save!
        render json: serialize(tc), status: :created
      end

      def update
        tc = @plan.test_cases.find(params[:id])
        tc.update!(case_params)
        render json: serialize(tc)
      end

      # POST /api/v1/projects/:slug/test_plans/:plan_id/test_cases/bulk
      # { cases: [ { title, steps, expected_result, api_call?, task_id?, position? }, ... ] }
      def bulk
        cases = Array(params[:cases])
        created = []
        TestCase.transaction do
          cases.each do |row|
            params_row = row.is_a?(ActionController::Parameters) ? row : ActionController::Parameters.new(row)
            permitted = params_row.permit(:title, :steps, :expected_result, :api_call, :task_id, :position, :notes)
            created << @plan.test_cases.create!(permitted)
          end
        end
        render json: { count: created.size, cases: created.map { |c| serialize(c) } }, status: :created
      end

      private

      def find_plan!
        @plan = @project.test_plans.find(params[:test_plan_id])
      end

      def case_params
        raw = params[:test_case] || params
        raw.permit(:title, :steps, :expected_result, :api_call, :task_id, :position, :notes)
      end

      def serialize(c)
        { id: c.id, position: c.position, title: c.title, steps: c.steps,
          expected_result: c.expected_result, api_call: c.api_call, task_id: c.task_id, notes: c.notes }
      end
    end
  end
end
