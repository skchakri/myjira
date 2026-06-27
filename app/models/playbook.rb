# A saved, reusable run recipe. Composes three things that already exist —
# SessionLaunch.queue! (one-shot run), AgentSchedule (cron), and the per-launch
# outcome metrics — into a repeatable, pass/fail-tracked unit. A playbook is a
# prompt/steps body plus explicit success criteria and guardrails, optionally
# bound to an Agent and/or a Project. It can be #trigger!ed (→ a SessionLaunch)
# or scheduled (→ an AgentSchedule carrying playbook_id); every fire records a
# PlaybookRun so the playbook accrues pass/fail history (see #metrics). This
# upgrades the one-shot agent_builds flow into repeatable measurable workflows.
class Playbook < ApplicationRecord
  belongs_to :project, optional: true
  belongs_to :agent,   optional: true
  has_many :playbook_runs, dependent: :destroy
  has_many :agent_schedules, dependent: :nullify

  validates :name, presence: true
  validates :body, presence: true
  validates :model, inclusion: { in: SessionLaunch::MODELS }, allow_blank: true
  validates :permission_mode, inclusion: { in: SessionLaunch::PERMISSION_MODES }, allow_blank: true

  scope :recent,  -> { order(created_at: :desc) }
  scope :enabled, -> { where(enabled: true) }

  # The launch prompt: the body, then a Success criteria block and a Guardrails
  # block when present, framed by the bound agent's launch_prompt when set. Pure,
  # so #trigger! and a scheduled fire build the prompt identically.
  def run_prompt
    parts = []
    parts << agent.launch_prompt if agent
    parts << body.to_s.strip
    parts << "Success criteria:\n#{success_criteria.strip}" if success_criteria.present?
    parts << "Guardrails:\n#{guardrails.strip}" if guardrails.present?
    parts.compact_blank.join("\n\n")
  end

  # Queue a SessionLaunch from run_prompt in `for_project`'s repo and record a
  # pending PlaybookRun bound to it. Returns the run, or nil when no project with
  # a repo_path is available (a global playbook needs one selected to run).
  def trigger!(for_project: project)
    return nil if for_project.nil? || for_project.repo_path.blank?

    launch = SessionLaunch.queue!(
      project: for_project,
      prompt: run_prompt,
      model: model.presence || "default",
      permission_mode: permission_mode.presence || "default",
      agent: agent,
      title: "▶ #{name}",
      source: "playbook"
    )
    playbook_runs.create!(session_launch: launch, result: "pending")
  end

  # Bulk pass/fail rollup over a set of playbooks — ONE query, grouped in Ruby —
  # so the index never N+1s. Mirrors Agent.metrics_for, but keyed off
  # PlaybookRun#result (did the run meet the criteria), not a launch spawn-outcome.
  # Returns a hash keyed by playbook id with a zero-filled entry for *every*
  # playbook passed (even never-run ones), so callers index without nil-checking:
  #   { playbook_id => { runs:, passed:, failed:, pending:, inconclusive:,
  #                      pass_rate:, last_run_at:,
  #                      sparkline: [7 ints, oldest→newest incl. today] } }
  def self.metrics_for(playbooks)
    ids = Array(playbooks).map { |p| p.is_a?(Playbook) ? p.id : p }.compact.uniq
    today   = Time.zone.now.to_date
    buckets = (0..6).to_h { |n| [today - (6 - n), n] }
    metrics = ids.index_with do
      { runs: 0, passed: 0, failed: 0, pending: 0, inconclusive: 0,
        pass_rate: 0, last_run_at: nil, sparkline: Array.new(7, 0) }
    end
    return metrics if ids.empty?

    PlaybookRun.where(playbook_id: ids)
               .pluck(:playbook_id, :result, :evaluated_at, :created_at)
               .each do |playbook_id, result, evaluated_at, created_at|
      m  = metrics[playbook_id]
      at = evaluated_at || created_at
      m[:runs] += 1
      m[result.to_sym] += 1 if m.key?(result.to_sym)
      m[:last_run_at] = at if at && (m[:last_run_at].nil? || at > m[:last_run_at])
      idx = buckets[at&.in_time_zone&.to_date]
      m[:sparkline][idx] += 1 if idx
    end
    metrics.each_value do |m|
      decided = m[:passed] + m[:failed]
      m[:pass_rate] = decided.positive? ? (m[:passed] * 100.0 / decided).round : 0
    end
    metrics
  end

  # This playbook's metrics slice — for the detail panel. Pass a metrics_for hash
  # to reuse a bulk query; otherwise runs its own one query.
  def metrics(preloaded = nil)
    (preloaded || self.class.metrics_for([self]))[id]
  end
end
