require "open3"
require "json"
require "timeout"

# Folds a captured Claude CLI session into enriched board tickets.
#
# Triggered (throttled) off the conversation sync. One `claude` pass over the
# session transcript does BOTH jobs at once: segment the session into topics and
# author, per topic, the four enrichment sections (Done / Assumptions / Test plan
# / Pros & cons). Each topic then find-or-creates ONE board Task in the session's
# project, keyed by a stable `external_ref` so re-runs update in place instead of
# duplicating. The running list of asks is folded into the task description (a
# managed block, so human edits above it survive); the enrichment overwrites
# `implementation_notes` each pass. New tickets land in `board_state:"pending"`
# so the existing triage/autopilot pipeline picks them up normally.
#
# Best-effort: any failure (claude missing, timeout, bad JSON) is rescued and
# logged — the sync that enqueued this is never affected.
class BoardTicketFromSessionJob < ApplicationJob
  queue_as :default

  CLAUDE_TIMEOUT = 150
  MSG_CHARS      = 1_200
  TOTAL_CHARS    = 24_000
  MAX_TOPICS     = 8

  # Managed region inside the task description. Anything ABOVE the opening marker
  # is preserved (human edits); the region between the markers is regenerated each
  # pass from the model's current ask list, so it never piles up or clobbers.
  ASKS_BEGIN = "<!-- auto:asks -->".freeze
  ASKS_END   = "<!-- /auto:asks -->".freeze

  def perform(conversation_id)
    convo = Conversation.find(conversation_id)
    return unless Setting.auto_board_tickets?

    user_count = convo.substantive_user_message_count
    return if user_count.zero? # nothing substantive to log

    topics = segment(convo)
    if topics.present?
      topics.first(MAX_TOPICS).each { |t| upsert_ticket(convo, t) }
      # Only advance the throttle on a real enrichment pass — a fallback ticket
      # leaves the throttle open so a later window retries enrichment.
      convo.mark_board_enriched!(user_count)
    else
      # claude unavailable / unparseable: still record the ask as a single ticket
      # so nothing is lost; the four enrichment sections stay empty until a retry.
      upsert_ticket(convo, fallback_topic(convo))
    end
  rescue => e
    Rails.logger.error("[board-enrich] #{e.class}: #{e.message}")
  end

  private

  # --- ticket upsert ---------------------------------------------------------

  def upsert_ticket(convo, topic)
    key = topic["topic_key"].to_s.strip.presence
    return if key.blank?

    ref  = "cli:#{convo.session_id}:#{key}"
    task = convo.project.tasks.find_or_initialize_by(external_ref: ref)
    new_record = task.new_record?

    task.title       = topic["title"].to_s.strip.presence || task.title.presence || "Session topic"
    task.item_type   = ITEM_TYPES.include?(topic["item_type"]) ? topic["item_type"] : (task.item_type.presence || "task")
    task.source      = "claude-cli"
    task.last_conversation = convo
    task.description = merged_description(task.description, Array(topic["asks"]))
    task.implementation_notes = enrichment_block(topic)
    # Only ever seed the lifecycle for a brand-new ticket; never reopen a ticket a
    # human or agent has since moved forward.
    if new_record
      task.board_state = "pending"
      task.status      = "open"
    end
    task.save!
  rescue => e
    Rails.logger.error("[board-enrich] upsert #{topic['topic_key']}: #{e.class}: #{e.message}")
  end

  ITEM_TYPES = Task::ITEM_TYPES

  # Preserve any human-authored prose above the managed marker; (re)write the asks
  # list inside the marker region. For a fresh ticket the description is just the
  # managed block.
  def merged_description(existing, asks)
    block = render_asks_block(asks)
    text  = existing.to_s
    if text.include?(ASKS_BEGIN) && text.include?(ASKS_END)
      pre = text.split(ASKS_BEGIN, 2).first.to_s.rstrip
      pre.empty? ? block : "#{pre}\n\n#{block}"
    elsif text.strip.empty?
      block
    else
      "#{text.rstrip}\n\n#{block}"
    end
  end

  def render_asks_block(asks)
    lines = asks.map { |a| a.to_s.strip }.reject(&:empty?).map { |a| "- #{a}" }
    body  = lines.any? ? lines.join("\n") : "_(no asks captured)_"
    [ASKS_BEGIN, "### Asks this session", body, ASKS_END].join("\n")
  end

  def enrichment_block(topic)
    [
      "### What Claude did",
      topic["done"].to_s.strip.presence || "—",
      "",
      "### Assumptions",
      topic["assumptions"].to_s.strip.presence || "—",
      "",
      "### Test plan",
      topic["test_plan"].to_s.strip.presence || "—",
      "",
      "### Pros & cons",
      topic["pros_cons"].to_s.strip.presence || "—"
    ].join("\n")
  end

  # --- claude segmentation + enrichment --------------------------------------

  # Returns the model's topic list, or [] if claude is unavailable/unparseable —
  # callers fall back to a single un-enriched ticket so the ask is never dropped.
  def segment(convo)
    parse_topics(run_claude(build_prompt(convo)))
  rescue => e
    Rails.logger.error("[board-enrich] segment failed: #{e.class}: #{e.message}")
    []
  end

  # One ticket for the whole session, asks pulled straight from the transcript,
  # no enrichment — used when the claude segmentation pass can't run.
  def fallback_topic(convo)
    asks = convo.conversation_messages.where(role: "user", kind: "message")
                .where.not(body: [nil, ""]).order(:position)
                .map { |m| m.body.to_s.split("\n").map(&:strip).find(&:present?).to_s.truncate(200) }
                .reject(&:empty?)
    {
      "topic_key" => "session",
      "title"     => convo.display_title,
      "item_type" => "task",
      "asks"      => asks
    }
  end

  def build_prompt(convo)
    <<~PROMPT
      You are segmenting a Claude CLI coding session into board tickets and enriching each one.

      Read the transcript below. Split it into 1 to #{MAX_TOPICS} distinct TOPICS — start a new
      topic only when the subject of work genuinely changes (not for every follow-up on the same
      thing). Most sessions are a single topic.

      Return ONLY a JSON object, no prose, no markdown fences, of this exact shape:
      {
        "topics": [
          {
            "topic_key": "stable-kebab-slug-describing-the-topic",
            "title": "short imperative ticket title",
            "item_type": "task | feature | issue | ask",
            "asks": ["each distinct thing the user asked for, verbatim-ish, in order"],
            "done": "what Claude actually did for this topic",
            "assumptions": "key assumptions Claude made",
            "test_plan": "how to verify this topic's work",
            "pros_cons": "pros and cons of the chosen approach"
          }
        ]
      }

      Rules:
      - topic_key must be a stable slug derived from the topic's subject (so re-running on a
        longer transcript yields the SAME key for the same topic). Lowercase, hyphens only.
      - item_type: "issue" for a bug, "feature" for new capability, "ask" for a pure question,
        else "task".
      - Keep every string concise. Output strictly valid JSON and nothing else.

      Session: #{convo.display_title}

      --- TRANSCRIPT ---
      #{transcript(convo)}
    PROMPT
  end

  def transcript(convo)
    who = { "user" => "User", "assistant" => "Claude" }
    out = +""
    convo.conversation_messages.where(kind: "message").order(:position).each do |m|
      body = m.body.to_s.strip
      next if body.empty?
      body = "#{body[0, MSG_CHARS]}…" if body.length > MSG_CHARS
      line = "#{who[m.role] || m.role}: #{body}\n"
      break if out.length + line.length > TOTAL_CHARS
      out << line
    end
    out.presence || "(empty conversation)"
  end

  def run_claude(prompt)
    out = +""
    Open3.popen2e({ "NO_COLOR" => "1" }, "claude", "-p", prompt, "--output-format", "json") do |stdin, stdout_err, wait_thr|
      stdin.close
      begin
        Timeout.timeout(CLAUDE_TIMEOUT) do
          stdout_err.each_line { |l| out << l }
          status = wait_thr.value
          raise "claude CLI exited #{status.exitstatus}: #{out[0, 400]}" unless status.success?
        end
      rescue Timeout::Error
        Process.kill("TERM", wait_thr.pid) rescue nil
        raise "claude CLI timed out after #{CLAUDE_TIMEOUT}s"
      end
    end
    out
  end

  # The CLI wraps the model output in {"result": "...", "is_error": ...}; the model
  # output is itself the topics JSON. Unwrap, then pull the JSON object out of any
  # stray prose / code fences.
  def parse_topics(raw)
    text = unwrap_cli(raw)
    obj  = JSON.parse(extract_json(text))
    Array(obj["topics"])
  rescue JSON::ParserError => e
    Rails.logger.error("[board-enrich] JSON parse: #{e.message}; raw=#{raw.to_s[0, 300]}")
    []
  end

  def unwrap_cli(raw)
    parsed = JSON.parse(raw)
    raise "claude returned an error: #{parsed['result']}" if parsed["is_error"]
    parsed["result"].to_s
  rescue JSON::ParserError
    raw.to_s
  end

  def extract_json(text)
    s = text.to_s.strip.sub(/\A```(?:json)?\s*/, "").sub(/```\s*\z/, "")
    first = s.index("{")
    last  = s.rindex("}")
    return s if first.nil? || last.nil?
    s[first..last]
  end
end
