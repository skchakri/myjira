# Web side of "add an MCP server" — both the one-click catalog gallery and the
# custom-add form post here. We compose the spec (catalog entry + the user's
# inputs, or the raw custom fields) into an McpInstall; the host daemon polls it
# and runs `claude mcp add` (Api::V1::McpInstallsController). Removal lives in
# McpServersController#destroy. Default scope is "user" (global, ~/.claude.json);
# project/local scope writes into the repo, so it needs a known repo_path.
class McpInstallsController < ApplicationController
  def create
    @project = find_project!
    scope = McpInstall::SCOPES.include?(params[:scope].to_s) ? params[:scope] : "user"

    if scope != "user" && @project.repo_path.blank?
      return redirect_back fallback_location: project_conversations_path(@project),
        alert: "No repo path known for #{@project.name} yet — run Claude there once so myjira can write its .mcp.json."
    end

    spec = params[:catalog_key].present? ? compose_from_catalog(params[:catalog_key]) : compose_custom
    if spec.nil? || spec[:name].blank?
      return redirect_back fallback_location: project_conversations_path(@project),
        alert: "Couldn't add MCP server: a name is required."
    end

    install = McpInstall.queue_add!(
      name: spec[:name], transport: spec[:transport], command: spec[:command], url: spec[:url],
      args: spec[:args], header: spec[:header], env: spec[:env],
      scope: scope, project: (scope == "user" ? nil : @project), catalog_key: spec[:catalog_key]
    )
    redirect_back fallback_location: project_conversations_path(@project),
      notice: "Adding MCP server “#{install.name}” (#{scope} scope) — it'll appear below once the daemon configures it."
  rescue ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: project_conversations_path(@project),
      alert: "Couldn't add MCP server: #{e.record.errors.full_messages.to_sentence}"
  end

  # The auto-reloading "Configuring MCP" strip on the Conversations hub — in-flight
  # and just-finished installs across all projects. Rendered layout-less into a
  # turbo frame, like SessionLaunchesController#active.
  def active
    @installs = McpInstall.active.recent.includes(:project).limit(12)
    render layout: false
  end

  private

  def find_project!
    Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
  end

  # A curated catalog entry plus whatever inputs the user supplied. Each input
  # routes to env / an extra arg / a header / the url, per its "target".
  def compose_from_catalog(key)
    entry = Mcp::Catalog.find(key)
    return nil unless entry

    args    = Array(entry["args"]).dup
    header  = []
    env     = {}
    url     = entry["url"]
    command = entry["command"]

    Array(entry["inputs"]).each do |input|
      val = params.dig(:inputs, input["key"]).to_s.strip
      next if val.blank?

      case input["target"]
      when "arg"    then args << val
      when "header" then header << "#{input["key"]}: #{val}"
      when "url"    then url = val
      else               env[input["key"]] = val # default target is env
      end
    end

    { name: entry["name"], transport: entry["transport"], command: command, url: url,
      args: args, header: header, env: env, catalog_key: key }
  end

  # A fully hand-entered server from the custom form.
  def compose_custom
    transport = McpInstall::TRANSPORTS.include?(params[:transport].to_s) ? params[:transport] : "stdio"
    {
      name: params[:name].to_s.strip,
      transport: transport,
      command: params[:command].presence,
      url: params[:url].presence,
      args: split_lines(params[:args]),
      header: key_value_rows(params[:mcp_header]).map { |k, v| "#{k}: #{v}" },
      env: key_value_rows(params[:mcp_env]).to_h,
      catalog_key: nil
    }
  end

  # A textarea of one-per-line tokens → array (blanks dropped).
  def split_lines(text)
    text.to_s.split("\n").map(&:strip).reject(&:blank?)
  end

  # Repeated [{ key:, value: }] form rows → [[k, v], …], dropping blank keys.
  def key_value_rows(rows)
    Array(rows).filter_map do |row|
      r = row.respond_to?(:to_unsafe_h) ? row.to_unsafe_h : row
      k = r["key"].to_s.strip
      [k, r["value"].to_s] if k.present?
    end
  end
end
