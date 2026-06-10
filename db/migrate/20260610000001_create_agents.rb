class CreateAgents < ActiveRecord::Migration[8.1]
  def change
    # The AI agents / skills / slash-commands discovered in a project's repo
    # (its .claude/{agents,skills,commands}) plus the global ~/.claude ones.
    # myjira runs in a container and can't read the host filesystem, so the
    # host-side launcher daemon walks these dirs and POSTs the catalogue to
    # /api/v1/agents/sync — exactly how repo_path and git branches get in.
    # Each row is something the user can click to TRIGGER: we turn it into a
    # SessionLaunch (a fresh `claude` started with a generated prompt).
    create_table :agents, id: :uuid do |t|
      # null project_id → a global entry (a ~/.claude skill/agent), shown in
      # every project's strip and tagged "global".
      t.references :project, type: :uuid, null: true, foreign_key: true

      t.string  :kind,   null: false             # agent | skill | command
      t.string  :name,   null: false             # frontmatter name or filename
      t.string  :scope,  null: false, default: "project"  # project | global
      t.text    :description
      t.string  :model                           # frontmatter --model hint, if any
      t.jsonb   :tools, default: [], null: false  # declared tools/allowed-tools
      t.string  :source_path                     # host path the daemon found it at
      t.boolean :enabled, null: false, default: true  # false → file vanished
      t.datetime :discovered_at

      t.timestamps
    end

    # One row per (project, kind, name). Globals (project_id NULL) get their own
    # partial unique index since NULLs are distinct in a composite unique index.
    add_index :agents, [:project_id, :kind, :name], unique: true,
              name: "index_agents_on_project_kind_name"
    add_index :agents, [:kind, :name], unique: true, where: "project_id IS NULL",
              name: "index_agents_on_global_kind_name"
    add_index :agents, :enabled
  end
end
