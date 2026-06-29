module Api
  module V1
    # Endpoints for the host-side launcher daemon (myjira_session_launcher.py).
    #
    #   GET   /api/v1/session_launches/pending   — queued launches to spawn
    #   PATCH /api/v1/session_launches/:id        — daemon reports status/tmux/error
    #
    # No auth, local-only, like the rest of the API. The daemon claims each launch
    # (PATCH status=launching) before spawning so a re-poll never double-spawns.
    class SessionLaunchesController < BaseController
      def pending
        launches = SessionLaunch.pending.order(:created_at).limit(20).includes(:project)
        render json: launches.map { |l| daemon_view(l) }
      end

      def update
        launch = SessionLaunch.find(params[:id])
        attrs = {}
        attrs[:status]      = params[:status]      if SessionLaunch::STATUSES.include?(params[:status].to_s)
        attrs[:tmux_target] = params[:tmux_target] if params.key?(:tmux_target)
        attrs[:error]       = params[:error]       if params.key?(:error)
        attrs[:launched_at] = Time.current         if params[:status].to_s == "launched"
        launch.update!(attrs) if attrs.any?
        render json: daemon_view(launch)
      end

      private

      def daemon_view(launch)
        {
          id: launch.id,
          session_id: launch.session_id,
          repo_path: launch.repo_path,
          prompt: launch.prompt,
          model: launch.model_flag,
          permission_mode: launch.permission_mode_flag,
          status: launch.status,
          source: launch.source,
          resume_of_session_id: launch.resume_of_session_id,
          project: launch.project.slug
        }
      end
    end
  end
end
