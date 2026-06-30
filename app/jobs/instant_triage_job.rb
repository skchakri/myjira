require "json"

# Fires a single cheap Haiku call immediately after a board item is created to
# produce a triage suggestion (agent_role, priority, labels[], plan_sketch).
# If the project has auto_triage_enabled, the fields are applied directly.
# Otherwise the suggestion is stored in task.triage_suggestion and surfaced as
# dismissable chips on the board row via the after_update_commit broadcast.
class InstantTriageJob < ApplicationJob
  queue_as :default

  MODEL      = "claude-haiku-4-5-20251001".freeze
  MAX_TOKENS = 256

  SYSTEM_PROMPT = <<~SYS.strip
    You are a concise project triage assistant. Given a board item, reply with ONLY
    valid JSON (no markdown fences, no prose) in this exact shape:
    {
      "agent_role":  "engineering | debugger | answer_only",
      "priority":    "low | normal | high | urgent",
      "labels":      ["at most 3 short kebab-case tags"],
      "plan_sketch": "one sentence describing what needs to be built or resolved"
    }
  SYS

  def perform(task_id)
    task = Task.find_by(id: task_id)
    return unless task
    return if task.triage_suggestion.present?
    return unless task.board_state == "pending"

    suggestion = call_api(task)
    return unless suggestion

    task.reload
    return unless task.board_state == "pending"

    if task.project.auto_triage_enabled?
      apply_suggestion!(task, suggestion)
    else
      task.update!(triage_suggestion: suggestion)
    end

    # After triage, fold any related pending items into one (reversible).
    Board::Consolidator.run!(task.reload) if task.board_state == "pending"
  rescue => e
    Rails.logger.error("[instant-triage] #{task_id}: #{e.class}: #{e.message}")
  end

  private

  def call_api(task)
    api_key = ENV["ANTHROPIC_API_KEY"].to_s.strip
    unless api_key.present?
      Rails.logger.warn("[instant-triage] ANTHROPIC_API_KEY not set — skipping #{task.id}")
      return nil
    end
    client = Anthropic::MessagesClient.new(api_key: api_key)
    raw = client.complete(
      model:      MODEL,
      max_tokens: MAX_TOKENS,
      system:     SYSTEM_PROMPT,
      user:       build_prompt(task)
    )
    parse_suggestion(raw)
  rescue Anthropic::Error => e
    Rails.logger.warn("[instant-triage] API error for #{task.id}: #{e.message}")
    nil
  end

  def build_prompt(task)
    parts = ["Project: #{task.project.name}", "Title: #{task.title}"]
    parts << "Description: #{task.description.to_s.truncate(800)}" if task.description.present?
    parts.join("\n")
  end

  def parse_suggestion(raw)
    text = raw.to_s.strip.sub(/\A```(?:json)?\s*/i, "").sub(/```\s*\z/, "")
    json = JSON.parse(text)

    role    = json["agent_role"].to_s
    prio    = json["priority"].to_s
    labels  = Array(json["labels"]).map { |l| l.to_s.strip.downcase }.first(3).select(&:present?)
    sketch  = json["plan_sketch"].to_s.strip.truncate(200)

    {
      "agent_role"  => Task::AGENT_ROLES.include?(role) ? role : nil,
      "priority"    => Task::PRIORITIES.include?(prio) ? prio : nil,
      "labels"      => labels,
      "plan_sketch" => sketch.presence
    }.compact
  rescue JSON::ParserError => e
    Rails.logger.warn("[instant-triage] JSON parse error: #{e.message}; raw=#{raw.to_s.truncate(200)}")
    nil
  end

  def apply_suggestion!(task, suggestion)
    attrs = {}
    attrs[:agent_role] = suggestion["agent_role"] if suggestion["agent_role"].present? && task.agent_role == "unassigned"
    attrs[:priority]   = suggestion["priority"]   if suggestion["priority"].present?
    if suggestion["labels"].present?
      existing = Array(task.labels)
      attrs[:labels] = (existing + suggestion["labels"]).uniq.first(5)
    end
    task.update!(attrs) if attrs.present?
  end
end
