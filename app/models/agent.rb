# An AI agent, skill, or slash-command discovered in a project's repo (or the
# global ~/.claude). Discovered host-side by the launcher daemon and synced via
# Api::V1::AgentsController. The point of the row is that you can TRIGGER it from
# the web: Agent#launch_prompt turns it into the prompt for a fresh `claude`
# session, which SessionLaunch + the daemon then spawn. See db migration notes.
class Agent < ApplicationRecord
  KINDS  = %w[agent skill command].freeze
  SCOPES = %w[project global].freeze

  belongs_to :project, optional: true
  has_many :session_launches, dependent: :nullify
  has_many :agent_schedules, dependent: :nullify

  validates :name, presence: true
  validates :kind,  inclusion: { in: KINDS }
  validates :scope, inclusion: { in: SCOPES }

  scope :enabled, -> { where(enabled: true) }
  scope :for_scope, ->(s) { where(scope: s) }
  # Agents first, then skills, then commands; alpha within each kind.
  scope :ordered, lambda {
    order(Arel.sql("CASE kind WHEN 'agent' THEN 0 WHEN 'skill' THEN 1 ELSE 2 END"), :name)
  }

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

  # Clicking a subagent with no objective: tell the session to run it for what
  # its own description says it's for.
  def default_agent_prompt
    desc = description.to_s.strip
    base = "Use the #{name} subagent"
    desc.present? ? "#{base}. Its job: #{desc.truncate(280)}" : "#{base} now."
  end
end
