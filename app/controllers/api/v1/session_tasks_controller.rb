module Api
  module V1
    # Slim lookup: given a CLI session_id, return the board task it belongs to.
    # Used by the myjira_block_guard.py PreToolUse hook to know which task to
    # update without reading the full launches pending list.
    #
    #   GET /api/v1/sessions/:session_id/task
    #   → { task_id, board_state, project_slug } or 404
    class SessionTasksController < BaseController
      def show
        launch = SessionLaunch.find_by(session_id: params[:session_id].to_s)
        task   = launch&.task
        return render json: { error: "not_found" }, status: :not_found unless task

        render json: {
          task_id:      task.id,
          board_state:  task.board_state,
          project_slug: task.project.slug,
          agent_notes:  task.agent_notes
        }
      end
    end
  end
end
