class CreateMcpInstalls < ActiveRecord::Migration[8.1]
  def change
    # A request, filed from the web, to add or remove an MCP server in Claude
    # Code's config. myjira can't run `claude mcp ...` itself (containerised), so
    # the host-side launcher daemon polls these, runs the command on the host
    # (arg-list, never a shell), and reports status back — the same intent-row
    # pattern as session_launches. One-click adds carry a catalog_key (the entry
    # in app/data/mcp_catalog.json); custom adds carry the full spec.
    create_table :mcp_installs, id: :uuid do |t|
      # null project_id → a user-scope (global) install; set for project/local.
      t.references :project, type: :uuid, null: true, foreign_key: true

      t.string :action, null: false, default: "add"  # add | remove
      t.string :name,   null: false                   # server name (claude mcp <name>)
      t.string :catalog_key                           # mcp_catalog.json entry, if one-click

      t.string :scope,     null: false, default: "user"  # user | project | local
      t.string :transport, null: false, default: "stdio" # stdio | sse | http
      t.string :command                              # stdio: the executable
      t.string :url                                  # http/sse: the endpoint
      t.jsonb  :args,   default: [], null: false      # stdio: command arguments
      t.jsonb  :header, default: [], null: false      # http/sse: -H "Name: value" headers

      # Secret env values (API keys/tokens), encrypted at rest. Handed to the
      # daemon over localhost only at poll time so `claude mcp add -e KEY=val`
      # can run unattended; mcp_servers persists only the key NAMES, never values.
      t.text :env

      # pending → installing (daemon claimed) → installed | failed | canceled
      t.string   :status, null: false, default: "pending"
      t.text     :error                              # daemon failure detail, if any
      t.datetime :installed_at

      t.timestamps
    end

    add_index :mcp_installs, :status
  end
end
