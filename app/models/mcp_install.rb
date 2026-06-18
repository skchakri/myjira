# A web-filed request to add or remove an MCP server in Claude Code's config.
# myjira can't run `claude mcp ...` itself (containerised), so the host-side
# launcher daemon polls pending installs, runs the command on the host as an
# arg-list (never a shell), and PATCHes status back — the same intent-row pattern
# as SessionLaunch. One-click adds carry a catalog_key (an entry in
# app/data/mcp_catalog.json); custom adds carry the full spec inline.
#
# Secret env values (API keys/tokens) are encrypted at rest and handed to the
# daemon only over the localhost API at poll time; the resulting McpServer row
# stores only the env key NAMES, never the values.
class McpInstall < ApplicationRecord
  ACTIONS    = %w[add remove].freeze
  SCOPES     = McpServer::SCOPES
  TRANSPORTS = McpServer::TRANSPORTS
  STATUSES   = %w[pending installing installed failed canceled].freeze
  # Server names are interpolated nowhere shell-y (the daemon uses arg-lists),
  # but keep them to the charset Claude itself accepts as defense-in-depth.
  NAME_FORMAT = /\A[a-zA-Z0-9_.-]+\z/

  belongs_to :project, optional: true

  serialize :env, coder: JSON
  encrypts  :env

  validates :action, inclusion: { in: ACTIONS }
  validates :name, presence: true, format: { with: NAME_FORMAT }
  validates :scope,     inclusion: { in: SCOPES }
  validates :transport, inclusion: { in: TRANSPORTS }
  validates :status,    inclusion: { in: STATUSES }
  validate  :add_spec_present, if: -> { action == "add" }

  scope :recent,  -> { order(created_at: :desc) }
  scope :pending, -> { where(status: "pending") }
  # The "pending installs" strip: still in flight, or finished recently enough
  # that it's worth showing before the next sync turns it into an McpServer pill.
  scope :active, lambda {
    where(status: %w[pending installing])
      .or(where(status: %w[installed failed]).where(updated_at: 5.minutes.ago..))
  }

  # Queue an add. `env`/`header` are optional; `env` is a {NAME => value} hash of
  # secrets (stored encrypted). project nil → user (global) scope.
  def self.queue_add!(name:, transport: "stdio", command: nil, url: nil,
                      args: [], header: [], env: {}, scope: "user",
                      project: nil, catalog_key: nil)
    create!(
      action: "add", name: name, transport: transport, command: command, url: url,
      args: Array(args), header: Array(header), env: env.presence || {},
      scope: scope, project: project, catalog_key: catalog_key
    )
  end

  # Queue a removal of `name` at `scope` (project optional, for project/local).
  def self.queue_remove!(name:, scope: "user", project: nil)
    create!(action: "remove", name: name, scope: scope, project: project)
  end

  def done?
    %w[installed failed canceled].include?(status)
  end

  # Env var NAMES only (for display / for syncing into McpServer.env_keys).
  def env_keys
    (env || {}).keys
  end

  private

  # A stdio add needs a command; an http/sse add needs a URL. Removes need neither.
  def add_spec_present
    if transport == "stdio"
      errors.add(:command, "is required for a stdio server") if command.blank?
    elsif url.blank?
      errors.add(:url, "is required for an #{transport} server")
    end
  end
end
