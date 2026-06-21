# Web side of removing a configured MCP server: files an McpInstall "remove" for
# the host daemon to run with `claude mcp remove`. The McpServer row stays until
# the next sync confirms it's gone from Claude's config, then it's disabled.
# Adding servers lives in McpInstallsController#create.
class McpServersController < ApplicationController
  # Turbo-frame body: just this project's configured-server pills. Auto-reloaded
  # by the strip so an install/remove shows up without a full page refresh.
  def index
    @project = Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
    render layout: false
  end

  def destroy
    server  = McpServer.find(params[:id])
    project = server.project

    if server.scope != "user" && (project.nil? || project.repo_path.blank?)
      return redirect_back fallback_location: conversations_path,
        alert: "Can't remove #{server.name}: no repo path known for its project."
    end

    McpInstall.queue_remove!(name: server.name, scope: server.scope, project: project)
    redirect_back fallback_location: (project ? project_conversations_path(project) : conversations_path),
      notice: "Removing MCP server “#{server.name}” — it'll disappear once the daemon updates Claude's config."
  end
end
