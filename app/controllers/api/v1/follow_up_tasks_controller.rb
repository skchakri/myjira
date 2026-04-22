module Api
  module V1
    class FollowUpTasksController < BaseController
      before_action :find_project!

      def index
        scope = @project.follow_up_tasks.order(created_at: :desc)
        scope = scope.where(status: params[:status]) if params[:status].present?
        scope = scope.where(severity: params[:severity]) if params[:severity].present?
        render json: scope.map { |f| serialize(f) }
      end

      def create
        f = @project.follow_up_tasks.new(follow_up_params)
        f.task_id ||= params[:task_id]
        f.save!
        render json: serialize(f), status: :created
      end

      def update
        f = @project.follow_up_tasks.find(params[:id])
        f.update!(follow_up_params)
        render json: serialize(f)
      end

      private

      def follow_up_params
        raw = params[:follow_up_task] || params[:follow_up] || params
        raw.permit(:title, :description, :severity, :status, :kind, :task_id, :test_result_id)
      end

      def serialize(f)
        { id: f.id, title: f.title, description: f.description, severity: f.severity,
          status: f.status, kind: f.kind, task_id: f.task_id, test_result_id: f.test_result_id,
          created_at: f.created_at, updated_at: f.updated_at }
      end
    end
  end
end
