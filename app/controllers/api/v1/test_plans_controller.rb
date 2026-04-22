module Api
  module V1
    class TestPlansController < BaseController
      before_action :find_project!

      def index
        render json: @project.test_plans.order(created_at: :desc).map { |p| serialize(p) }
      end

      def show
        render json: serialize(@project.test_plans.find(params[:id]), detailed: true)
      end

      def create
        plan = @project.test_plans.new(plan_params)
        plan.save!
        attach_tasks(plan)
        render json: serialize(plan, detailed: true).merge(next_steps: next_steps_for(plan)), status: :created
      end

      def update
        plan = @project.test_plans.find(params[:id])
        plan.update!(plan_params)
        attach_tasks(plan)
        render json: serialize(plan, detailed: true).merge(next_steps: next_steps_for(plan))
      end

      private

      def plan_params
        raw = params[:test_plan] || params
        raw.permit(:title, :description, :status)
      end

      def attach_tasks(plan)
        ids = Array(params[:task_ids] || params.dig(:test_plan, :task_ids))
        return if ids.empty?
        tasks = @project.tasks.where(id: ids)
        tasks.each { |t| plan.test_plan_tasks.find_or_create_by!(task: t) }
      end

      def serialize(plan, detailed: false)
        data = {
          id: plan.id, title: plan.title, status: plan.status,
          description: plan.description,
          task_ids: plan.tasks.pluck(:id),
          case_count: plan.test_cases.count,
          urls: {
            web: "#{base_url}/projects/#{@project.slug}/test_plans/#{plan.id}",
            api: "#{base_url}/api/v1/projects/#{@project.slug}/test_plans/#{plan.id}"
          }
        }
        if detailed
          data[:tasks] = plan.tasks.map { |t| { id: t.id, title: t.title, status: t.status } }
          data[:test_cases] = plan.test_cases.map { |c| case_json(c) }
          data[:runs] = plan.test_runs.order(started_at: :desc).limit(10).map { |r| { id: r.id, status: r.status, progress: r.progress } }
        end
        data
      end

      def case_json(c)
        { id: c.id, position: c.position, title: c.title, steps: c.steps,
          expected_result: c.expected_result, api_call: c.api_call, task_id: c.task_id }
      end
    end
  end
end
