module Api
  module V1
    # Host-side MCP discovery → myjira. The launcher daemon enumerates Claude
    # Code's configured servers (`claude mcp list`, user-scope in ~/.claude.json
    # plus each repo's project-scope .mcp.json) and POSTs the set here. Mirrors
    # AgentsController#sync — myjira is containerised and can't read host config.
    #
    #   POST /api/v1/mcp_servers/sync
    #     { project: "<slug>"|null, scope: "user"|"project"|"local",
    #       servers: [ { name:, transport:, command:, url:, args:, env_keys:,
    #                     status:, status_detail: } ] }
    #
    # Idempotent full-set upsert per (project, scope): entries present are
    # created/updated; entries in that bucket the daemon no longer reports are
    # disabled, so removed servers drop out of the UI. No auth, local-only.
    class McpServersController < BaseController
      def sync
        project = Project.where(slug: params[:project]).first if params[:project].present?
        scope   = McpServer::SCOPES.include?(params[:scope].to_s) ? params[:scope] : (project ? "project" : "user")

        seen = []
        Array(params[:servers]).each do |raw|
          s    = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
          name = s["name"].to_s
          next if name.blank?

          server = McpServer.find_or_initialize_by(project_id: project&.id, scope: scope, name: name)
          server.assign_attributes(
            transport: McpServer::TRANSPORTS.include?(s["transport"].to_s) ? s["transport"] : "stdio",
            command: s["command"].presence,
            url: s["url"].presence,
            args: Array(s["args"]),
            env_keys: Array(s["env_keys"]),
            status: McpServer::STATUSES.include?(s["status"].to_s) ? s["status"] : "pending",
            status_detail: s["status_detail"].presence,
            enabled: true,
            discovered_at: Time.current
          )
          server.save!
          seen << server.id
        end

        # Anything in this (project, scope) bucket we didn't just see is gone.
        McpServer.where(project_id: project&.id, scope: scope)
                 .where.not(id: seen)
                 .update_all(enabled: false, updated_at: Time.current)

        render json: { ok: true, project: project&.slug, scope: scope, synced: seen.size }
      end
    end
  end
end
