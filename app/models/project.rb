class Project < ApplicationRecord
  has_many :environments, dependent: :destroy
  has_many :tasks, dependent: :destroy
  has_many :test_plans, dependent: :destroy
  has_many :follow_up_tasks, dependent: :destroy
  has_many :browser_tasks, dependent: :destroy
  has_many :conversations, dependent: :destroy
  has_many :session_launches, dependent: :destroy
  has_many :agents, dependent: :destroy
  has_many :agent_schedules, dependent: :destroy
  has_many :playbooks, dependent: :destroy
  has_many :mcp_servers, dependent: :destroy
  has_many :mcp_installs, dependent: :destroy
  has_many :knowledge_facts, dependent: :destroy

  # Workspace grouping. pyr = per-client iCentris/pyr checkouts; skchakri =
  # personal apps; icentris = the iCentris platform; mobile = Ionic/Capacitor
  # mobile apps; other = anything else.
  CATEGORIES     = %w[pyr skchakri icentris mobile other].freeze
  CATEGORY_ORDER = %w[skchakri pyr icentris mobile other].freeze

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true,
    format: { with: /\A[a-z0-9][a-z0-9\-_]*\z/, message: "must be lowercase, digits, - or _" }
  validates :category, inclusion: { in: CATEGORIES }, allow_nil: true

  before_validation :derive_slug, on: :create
  before_validation :assign_category, on: :create
  after_create :ensure_default_environments!

  # A "client" is a project that is either explicitly pinned (listed) or has real
  # myjira work — tasks, test plans, gaps, or relay (browser) tickets. Projects
  # that exist only to group captured CLI conversations (the sync hook makes one
  # per working dir) are NOT clients; they stay out of the Clients sidebar /
  # projects index and live under Conversations instead. Self-correcting: add any
  # real artifact and it appears; or set listed to pin it in deliberately.
  scope :clients, lambda {
    where(
      "projects.listed = TRUE " \
      "OR EXISTS (SELECT 1 FROM tasks t WHERE t.project_id = projects.id) " \
      "OR EXISTS (SELECT 1 FROM test_plans tp WHERE tp.project_id = projects.id) " \
      "OR EXISTS (SELECT 1 FROM follow_up_tasks f WHERE f.project_id = projects.id) " \
      "OR EXISTS (SELECT 1 FROM browser_tasks b WHERE b.project_id = projects.id)"
    )
  }

  # Archive is an axis orthogonal to `clients`: chain them, e.g.
  # `Project.clients.active` for the sidebar / default index, and
  # `Project.clients.archived` for the "Show archived" view. Archive wins over
  # `listed` — an archived project is hidden from the nav even when pinned.
  scope :active,   -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }

  DEFAULT_ENVIRONMENTS = [
    { name: "Development", base_url: nil },
    { name: "Stage",       base_url: nil },
    { name: "Prod",        base_url: nil }
  ].freeze

  # Derive a workspace category from a repo path (the bucketing rule, reused by
  # the backfill migration and on create).
  def self.category_for(repo_path)
    path = repo_path.to_s
    return "pyr"      if path.include?("/platform/clients")
    return "mobile"   if path.include?("/platform/icentris/ionic")
    return "icentris" if path.include?("/platform/icentris")
    return "skchakri" if path.match?(%r{/platform/skchakri|/platform/quapt|/pyr-docker|/platform/aws})
    "other"
  end

  def to_param
    slug
  end

  # Guarantee every project has Development / Stage / Prod envs. Development is
  # the default selection on the test-run form. Idempotent — safe to call on
  # existing projects for backfill.
  def ensure_default_environments!
    DEFAULT_ENVIRONMENTS.each do |row|
      next if environments.exists?(name: row[:name])
      base = row[:base_url] || default_base_url
      environments.create!(name: row[:name], base_url: base)
    end
  end

  def default_environment
    environments.find_by(name: "Development") || environments.order(:name).first
  end

  def archived?
    archived_at.present?
  end

  # Retire / restore a project. Archiving hides it from the nav and the default
  # projects index without touching its board or history; unarchiving brings it
  # straight back.
  def archive!
    update!(archived_at: Time.current)
  end

  def unarchive!
    update!(archived_at: nil)
  end

  # Triggerable agents shown for this folder: the ones discovered in its own
  # repo, plus every global skill/agent/command (available everywhere).
  def available_agents
    Agent.enabled.where("agents.project_id = :id OR agents.scope = 'global'", id: id).ordered
  end

  # MCP servers shown for this folder: the ones configured in its own repo
  # (project/local scope), plus every user-scope (global) server.
  def available_mcp_servers
    McpServer.enabled
             .where("mcp_servers.project_id = :id OR mcp_servers.scope = 'user'", id: id)
             .ordered
  end

  def rollup
    {
      tasks: tasks.count,
      open_tasks: tasks.where(status: %w[open in_progress]).count,
      test_plans: test_plans.count,
      open_follow_ups: follow_up_tasks.where(status: %w[open in_progress]).count,
      conversations: conversations.count
    }
  end

  # --- Project memory --------------------------------------------------------

  # How many learned facts ride along in a launch's prompt (the static preamble
  # is always included in full; facts are the most-recently-seen slice).
  MEMORY_FACT_LIMIT = 12

  # The combined "project memory" prepended into every agent launch: the
  # hand-written static preamble plus the top learned facts, as a labelled
  # bullet list. nil when there's nothing to inject (so launches with no memory
  # behave exactly as before — see SessionLaunch.queue!).
  def memory_block
    facts = knowledge_facts.current.limit(MEMORY_FACT_LIMIT).pluck(:body)
    return nil if memory_preamble.blank? && facts.empty?

    parts = ["# Project memory — #{name}"]
    parts << memory_preamble.strip if memory_preamble.present?
    if facts.any?
      parts << "Learned facts about this codebase:"
      parts << facts.map { |b| "- #{b}" }.join("\n")
    end
    parts.join("\n\n")
  end

  # --- Project Board / Autopilot ---------------------------------------------

  # A board launch is considered in flight while it is queued/launching, or while
  # its session is actively running — judged by recent conversation activity (a
  # quiet session is treated as finished) rather than a flat timeout, so the next
  # step starts promptly once an agent goes idle.
  BOARD_LAUNCH_BUSY_WINDOW = 8.minutes

  def board_items
    tasks.with_attached_attachments.board_ordered
  end

  # Branch agents fork from and target PRs at. Defaults to main when unset.
  def base_branch_or_default
    base_branch.presence || "main"
  end

  # Items grouped by board_state in the board's display order; empty groups dropped.
  # An optional `label:` narrows to items carrying that label (GIN-indexed scope).
  def board_groups(label: nil)
    scope = board_items
    scope = scope.with_label(label) if label.present?
    grouped = scope.group_by(&:board_state)
    Task::BOARD_GROUP_ORDER.filter_map do |state|
      items = grouped[state]
      [state, items] if items.present?
    end
  end

  # Distinct labels across this project's board items — drives the filter chips.
  def board_labels
    tasks.all_labels
  end

  # Next item the autopilot orchestrator should act on. Uses the work-queue order
  # (severity then FIFO), independent of the display `position`, so manual
  # drag-to-reorder on the board never changes what the agents pick up next.
  def next_board_item
    tasks.actionable.board_queue_ordered.first
  end

  def autopilot_runs_today
    autopilot_runs_on == Date.current ? autopilot_runs_count.to_i : 0
  end

  def autopilot_under_cap?
    autopilot_runs_today < autopilot_daily_cap.to_i
  end

  # Autopilot may launch for this project only when enabled, not paused, not
  # globally stopped, and under the daily cap.
  def autopilot_active?
    autopilot_enabled? && !autopilot_paused? && !Setting.autopilot_stopped? && autopilot_under_cap?
  end

  # Returns the in-flight board pipeline launch record (the one currently being
  # actively worked on), or nil when no step is running. Used to identify which
  # specific board item the autopilot is processing right now.
  def current_board_launch
    board_launches = session_launches.where.not(pipeline_step: nil)
    record = board_launches.where(status: %w[pending launching]).order(created_at: :desc).first
    return record if record

    board_launches.where(status: "launched").joins(:conversation)
                  .where("COALESCE(conversations.last_message_at, session_launches.launched_at) >= ?",
                         BOARD_LAUNCH_BUSY_WINDOW.ago)
                  .order(created_at: :desc).first
  end

  # True while a board pipeline step is still running for this project (enforces
  # the one-item-at-a-time guardrail).
  def inflight_board_launch?
    current_board_launch.present?
  end

  # State-based one-item-at-a-time guard: the autopilot picks the next item only
  # when this is false. A dead session's item is returned to the queue by the
  # daemon's session-sync leg (Board::SessionSync), so this can't wedge.
  #
  # Two conditions make the project busy:
  #   1. An in_progress task: the agent claimed the item and is actively working.
  #   2. A pending/launching board session: the daemon hasn't spawned the agent
  #      yet (gap between queue! and the agent calling the API to set in_progress).
  def board_busy?
    tasks.in_progress.exists? ||
      session_launches.where(status: %w[pending launching])
                      .where.not(pipeline_step: nil).exists?
  end

  # Roll the daily counter forward, resetting it on a new day.
  def bump_autopilot_runs!
    today = Date.current
    if autopilot_runs_on == today
      increment!(:autopilot_runs_count)
    else
      update!(autopilot_runs_on: today, autopilot_runs_count: 1)
    end
  end

  private

  def derive_slug
    return if slug.present?
    self.slug = name.to_s.downcase.strip.gsub(/[^a-z0-9]+/, "-").squeeze("-").gsub(/\A-|-\z/, "")
  end

  def assign_category
    self.category ||= self.class.category_for(repo_path)
  end
end
