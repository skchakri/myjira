module Api
  module V1
    # Append-only comments on a board item. Lets board agents (engineering /
    # debugger / answer) post progress or conflict notes that show in the same
    # log a human reads on the task page. author defaults to "agent".
    class CommentsController < BaseController
      before_action :find_project!

      def index
        render json: task.comments.map { |c| serialize(c) }
      end

      def create
        comment = task.comments.create!(comment_params)
        render json: serialize(comment), status: :created
      end

      private

      def task
        @task ||= @project.tasks.find(params[:task_id])
      end

      def comment_params
        raw = params[:comment] || params
        permitted = raw.permit(:author, :body)
        permitted[:author] = permitted[:author].presence || "agent"
        permitted
      end

      def serialize(comment)
        { id: comment.id, author: comment.author, body: comment.body, created_at: comment.created_at }
      end
    end
  end
end
