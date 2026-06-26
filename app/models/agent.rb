# An AI agent, skill, or slash-command discovered in a project's repo (or the
# global ~/.claude). Discovered host-side by the launcher daemon and synced via
# Api::V1::AgentsController. The point of the row is that you can TRIGGER it from
# the web: Agent#launch_prompt turns it into the prompt for a fresh `claude`
# session, which SessionLaunch + the daemon then spawn. See db migration notes.
class Agent < ApplicationRecord
  KINDS  = %w[agent skill command].freeze
  SCOPES = %w[project global].freeze

  # Buckets the strip groups by. Ordered as they should display, "general" last.
  CATEGORIES = %w[testing review docs refactor data frontend devops research general].freeze
  CATEGORY_LABELS = {
    "testing"  => "Testing & QA",
    "review"   => "Code review",
    "docs"     => "Docs & writing",
    "refactor" => "Refactor & architecture",
    "data"     => "Data & DB",
    "frontend" => "UI & frontend",
    "devops"   => "DevOps & infra",
    "research" => "Research",
    "general"  => "General"
  }.freeze
  # First matching rule wins; keep the most specific categories above "general".
  CATEGORY_RULES = [
    ["testing",  %w[test spec qa rspec pytest jest vitest cypress e2e coverage flaky regression]],
    ["review",   %w[review lint rubocop critique audit pr code-review brakeman security vulnerab]],
    ["frontend", %w[ui ux frontend css tailwind component design react vue svelte view layout styling]],
    ["data",     %w[data db database sql migration query embedding rag vector etl analytics schema]],
    ["devops",   %w[deploy docker kamal kubernetes k8s infra ci cd pipeline ops terraform nginx release]],
    ["docs",     %w[doc docs documentation readme changelog guide tutorial explainer writeup]],
    ["refactor", %w[refactor architecture cleanup simplify restructure pattern dependency modularize]],
    ["research", %w[research investigate explore gather summarize summary discover]]
  ].freeze

  belongs_to :project, optional: true
  has_many :session_launches, dependent: :nullify
  has_many :agent_schedules, dependent: :nullify

  validates :name, presence: true
  validates :kind,  inclusion: { in: KINDS }
  validates :scope, inclusion: { in: SCOPES }

  before_save :ensure_category

  scope :enabled, -> { where(enabled: true) }
  scope :for_scope, ->(s) { where(scope: s) }
  # Agents first, then skills, then commands; alpha within each kind.
  scope :ordered, lambda {
    order(Arel.sql("CASE kind WHEN 'agent' THEN 0 WHEN 'skill' THEN 1 ELSE 2 END"), :name)
  }

  # Keyword-classify an agent into a CATEGORY from its name/description/tools.
  # Pure (no DB), so the sync controller and the backfill migration both call it.
  def self.classify(name, description = nil, tools = nil)
    hay = "#{name} #{description} #{Array(tools).join(' ')}".downcase
    CATEGORY_RULES.each { |cat, words| return cat if words.any? { |w| hay.include?(w) } }
    "general"
  end

  # Bulk launcher metrics for a set of agents — ONE query, grouped in Ruby — so a
  # strip full of pills (or the whole hub) never N+1s. Returns a hash keyed by
  # agent id with a zeroed entry for *every* agent passed (even never-launched
  # ones), so callers can index without nil-checking:
  #   { agent_id => { runs:, succeeded:, failed:, cancelled:, running:,
  #                   last_run_at:, sparkline: [7 ints, oldest→newest incl. today] } }
  # Outcome is derived per row via SessionLaunch.outcome_for (time-dependent, so
  # not SQL-grouped). Sparkline buckets each launch by COALESCE(launched_at,
  # created_at) into trailing-7-day buckets in Time.zone.
  def self.metrics_for(agents)
    ids = Array(agents).map { |a| a.is_a?(Agent) ? a.id : a }.compact.uniq
    today   = Time.zone.now.to_date
    buckets = (0..6).to_h { |n| [today - (6 - n), n] } # date → sparkline index (oldest→newest)
    metrics = ids.index_with do
      { runs: 0, succeeded: 0, failed: 0, cancelled: 0, running: 0,
        last_run_at: nil, sparkline: Array.new(7, 0) }
    end
    return metrics if ids.empty?

    SessionLaunch.where(agent_id: ids)
                 .pluck(:agent_id, :status, :launched_at, :created_at)
                 .each do |agent_id, status, launched_at, created_at|
      m  = metrics[agent_id]
      at = launched_at || created_at
      m[:runs] += 1
      m[:last_run_at] = at if at && (m[:last_run_at].nil? || at > m[:last_run_at])
      m[SessionLaunch.outcome_for(status, launched_at).to_sym] += 1
      idx = buckets[at&.in_time_zone&.to_date]
      m[:sparkline][idx] += 1 if idx
    end
    metrics
  end

  # Launcher metrics for this one agent — for the disclosure detail panel. Pass a
  # `metrics_for` hash to reuse a bulk query; otherwise runs its own one query.
  def metrics(preloaded = nil)
    (preloaded || self.class.metrics_for([self]))[id]
  end

  # [[label, [agents…]], …] in CATEGORIES order, skipping empty buckets — what
  # the expanded strip renders as sub-grouped rows.
  def self.grouped(agents)
    by = agents.group_by { |a| a.category.presence || "general" }
    CATEGORIES.filter_map { |c| [CATEGORY_LABELS[c], by[c]] if by[c]&.any? }
  end

  def category_label
    CATEGORY_LABELS[category.presence || "general"] || "General"
  end

  KIND_GLYPH = { "agent" => "◆", "skill" => "✦", "command" => "⌘" }.freeze
  def glyph
    KIND_GLYPH[kind] || "•"
  end

  # The initial prompt for the `claude` session this agent launches. `task` is
  # the user-supplied objective/arguments from the trigger form (may be blank).
  #   agent   → "Use the <name> subagent to <task>"  (delegates to the subagent)
  #   skill   → "/<name> <task>"                       (invokes the skill)
  #   command → "/<name> <task>"                       (runs the slash command)
  def launch_prompt(task = nil)
    task = task.to_s.strip
    case kind
    when "agent"
      task.present? ? "Use the #{name} subagent to #{task}" : default_agent_prompt
    else
      ["/#{name}", task.presence].compact.join(" ")
    end
  end

  # The frontmatter --model value, but only if it's one the launcher accepts
  # (default/opus/sonnet/haiku); otherwise nil so the launch falls back to default.
  def launch_model
    SessionLaunch::MODELS.include?(model) ? model : nil
  end

  private

  # Fill the bucket from name/description when the daemon didn't supply one, so
  # ad-hoc saves still group sensibly. Sync sets category explicitly.
  def ensure_category
    self.category = self.class.classify(name, description, tools) if category.blank?
  end

  # Clicking a subagent with no objective: tell the session to run it for what
  # its own description says it's for.
  def default_agent_prompt
    desc = description.to_s.strip
    base = "Use the #{name} subagent"
    desc.present? ? "#{base}. Its job: #{desc.truncate(280)}" : "#{base} now."
  end
end
