module Api
  module V1
    # Endpoints for the host-side launcher daemon (myjira_session_launcher.py).
    #
    #   GET   /api/v1/mcp_installs/pending   — queued add/remove requests to run
    #   PATCH /api/v1/mcp_installs/:id        — daemon reports status/error back
    #
    # No auth, local-only, like the rest of the API. The daemon claims each row
    # (PATCH status=installing) before running `claude mcp ...` so a re-poll never
    # double-runs. The pending payload carries the DECRYPTED env secrets so the
    # daemon can configure token servers unattended — it travels over localhost
    # only and is never persisted in McpServer (which keeps env_keys, not values).
    class McpInstallsController < BaseController
      def pending
        installs = McpInstall.pending.order(:created_at).limit(20).includes(:project)
        render json: installs.map { |i| daemon_view(i) }
      end

      def update
        install = McpInstall.find(params[:id])
        attrs = {}
        attrs[:status]       = params[:status] if McpInstall::STATUSES.include?(params[:status].to_s)
        attrs[:error]        = params[:error]  if params.key?(:error)
        attrs[:installed_at] = Time.current    if params[:status].to_s == "installed"
        install.update!(attrs) if attrs.any?
        render json: daemon_view(install)
      end

      private

      def daemon_view(install)
        {
          id: install.id,
          action: install.action,
          name: install.name,
          scope: install.scope,
          transport: install.transport,
          command: install.command,
          url: install.url,
          args: Array(install.args),
          header: Array(install.header),
          env: install.env || {},
          repo_path: install.project&.repo_path,
          project: install.project&.slug,
          status: install.status
        }
      end
    end
  end
end
