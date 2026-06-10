class AddGitInsights < ActiveRecord::Migration[8.1]
  def change
    # Recent branches for the repo behind this project's working dir. Gathered
    # host-side by the conversation-sync hook (the Rails app runs in Docker and
    # can't see host repos) and refreshed on each sync.
    add_column :projects, :branches, :jsonb, default: [], null: false
    add_column :projects, :branches_synced_at, :datetime

    # Pull requests for this conversation's git_branch (host-side via `gh`), the
    # most-recent user prompt (the session's "last context"), and a distilled
    # list of what got done — all denormalised so the index list stays one query.
    add_column :conversations, :prs, :jsonb, default: [], null: false
    add_column :conversations, :last_context, :text
    add_column :conversations, :highlights, :jsonb, default: [], null: false
  end
end
