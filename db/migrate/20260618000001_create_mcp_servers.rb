class CreateMcpServers < ActiveRecord::Migration[8.1]
  def change
    # The MCP servers actually configured for Claude Code on the host — the
    # mirror of `claude mcp list` (user-scope ones in ~/.claude.json plus each
    # repo's project-scope .mcp.json). myjira runs in a container and can't read
    # the host config, so the host-side launcher daemon enumerates them and POSTs
    # the set to /api/v1/mcp_servers/sync — exactly how agents and repo_path get
    # in. One row per configured server; status reflects the daemon's last health
    # check so the UI can show ● connected / ◌ pending / ⚠ failed.
    create_table :mcp_servers, id: :uuid do |t|
      # null project_id → a user-scope (global) server, available in every
      # project and shown in every project's strip tagged "global".
      t.references :project, type: :uuid, null: true, foreign_key: true

      t.string  :name,      null: false              # server name (claude mcp <name>)
      t.string  :scope,     null: false, default: "user"  # user | project | local
      t.string  :transport, null: false, default: "stdio" # stdio | sse | http
      t.string  :command                             # stdio: the executable
      t.string  :url                                 # http/sse: the endpoint
      t.jsonb   :args,     default: [], null: false   # stdio: command arguments
      t.jsonb   :env_keys, default: [], null: false   # env var NAMES only (no values)
      t.string  :status,   null: false, default: "pending" # connected | pending | failed
      t.text    :status_detail                       # health-check message, if any
      t.boolean :enabled,  null: false, default: true # false → vanished from host config
      t.datetime :discovered_at

      t.timestamps
    end

    # One row per (project, scope, name). User-scope servers (project_id NULL)
    # get a partial unique index since NULLs are distinct in a composite unique.
    add_index :mcp_servers, [:project_id, :scope, :name], unique: true,
              name: "index_mcp_servers_on_project_scope_name"
    add_index :mcp_servers, [:scope, :name], unique: true, where: "project_id IS NULL",
              name: "index_mcp_servers_on_global_scope_name"
    add_index :mcp_servers, :enabled
  end
end
