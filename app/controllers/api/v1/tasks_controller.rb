module Api
  module V1
    class TasksController < BaseController
      before_action :find_project!

      def index
        render json: @project.tasks.recent.map { |t| serialize(t) }
      end

      def show
        render json: serialize(@project.tasks.find(params[:id]), detailed: true)
      end

      def create
        task = @project.tasks.new(task_params)
        resolve_environment(task)
        task.save!
        render json: serialize(task, detailed: true).merge(next_steps: next_steps_for(task)), status: :created
      end

      def update
        task = @project.tasks.find(params[:id])
        task.assign_attributes(task_params)
        resolve_environment(task)
        task.implemented_at ||= Time.current if task.status_changed? && %w[implemented ready_for_test].include?(task.status)
        task.save!
        render json: serialize(task, detailed: true).merge(next_steps: next_steps_for(task))
      end

      private

      def task_params
        raw = params[:task] || params
        raw.permit(:title, :description, :implementation_notes, :external_ref, :status, :priority, :source, :environment_id)
      end

      def resolve_environment(task)
        env_name = params[:environment] || params.dig(:task, :environment)
        return if env_name.blank? && task.environment_id.present?
        return if env_name.blank?
        env = @project.environments.find_or_create_by!(name: env_name)
        task.environment = env
      end

      def serialize(task, detailed: false)
        data = {
          id: task.id, title: task.title, status: task.status, priority: task.priority,
          source: task.source, external_ref: task.external_ref,
          environment: task.environment&.name,
          implemented_at: task.implemented_at,
          created_at: task.created_at, updated_at: task.updated_at,
          urls: {
            web: "#{base_url}/projects/#{@project.slug}/tasks/#{task.id}",
            api: "#{base_url}/api/v1/projects/#{@project.slug}/tasks/#{task.id}"
          }
        }
        if detailed
          data[:description] = task.description
          data[:implementation_notes] = task.implementation_notes
          data[:test_plans] = task.test_plans.map { |p| { id: p.id, title: p.title, status: p.status } }
          data[:follow_ups] = task.follow_up_tasks.order(created_at: :desc).map { |f| { id: f.id, title: f.title, severity: f.severity, status: f.status, kind: f.kind } }
        end
        data
      end
    end
  end
end
