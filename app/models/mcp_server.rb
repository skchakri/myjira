# An MCP server configured for Claude Code on the host — the mirror of one entry
# in `claude mcp list` (user-scope ones in ~/.claude.json, project-scope ones in
# a repo's .mcp.json). Discovered host-side by the launcher daemon and synced via
# Api::V1::McpServersController, exactly like Agent. The row is read-only state:
# you don't edit it here, you file an McpInstall to add/remove and the daemon
# reconciles. See db migration notes.
class McpServer < ApplicationRecord
  SCOPES     = %w[user project local].freeze
  TRANSPORTS = %w[stdio sse http].freeze
  STATUSES   = %w[connected pending failed].freeze
  # Mirror of McpInstall::REMOTE_URL_FORMAT — a synced remote server must carry a
  # real http(s) endpoint. Applied only when a url is present so stdio rows (no
  # url) and partially-synced rows aren't rejected.
  REMOTE_URL_FORMAT = %r{\Ahttps?://}

  belongs_to :project, optional: true

  validates :name, presence: true
  validates :scope,     inclusion: { in: SCOPES }
  validates :transport, inclusion: { in: TRANSPORTS }
  validates :url, format: { with: REMOTE_URL_FORMAT }, if: -> { url.present? }

  scope :enabled,   -> { where(enabled: true) }
  scope :for_scope, ->(s) { where(scope: s) }
  # User-scope (global) first, then project, then local; alpha within each.
  scope :ordered, lambda {
    order(Arel.sql("CASE scope WHEN 'user' THEN 0 WHEN 'project' THEN 1 ELSE 2 END"), :name)
  }

  STATUS_GLYPH = { "connected" => "●", "pending" => "◌", "failed" => "⚠" }.freeze
  def status_glyph
    STATUS_GLYPH[status] || "◌"
  end

  # A user-scope server (project_id NULL) is available in every project — tagged
  # "global" in the UI, the same way global agents are.
  def global?
    scope == "user" || project_id.nil?
  end

  # What the strip shows under the name: the command (stdio) or endpoint (http/sse).
  def endpoint_label
    transport == "stdio" ? [command, *Array(args)].compact.join(" ") : url.to_s
  end
end
