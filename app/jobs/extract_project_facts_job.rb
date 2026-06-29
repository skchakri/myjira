require "open3"
require "json"
require "timeout"

# Mines a settled CLI conversation for a few durable, reusable facts about the
# project's codebase ("auth lives in app/services/auth", "UUID PKs everywhere",
# "e2e tests in spec/e2e") by shelling out to the local `claude` CLI — same
# Open3 pattern as SummarizeConversationJob. The facts are upserted into
# KnowledgeFact (deduped, capped) so the NEXT launch in this project skips the
# file-exploration warm-up this session already did.
#
# Triggered debounced from the conversations sync endpoint once a session has
# settled; stamps conversations.facts_extracted_at so repeated idempotent syncs
# don't re-run it. Best-effort: a thin transcript or a bad LLM response is a
# no-op, never a raise.
class ExtractProjectFactsJob < ApplicationJob
  queue_as :default

  CLAUDE_TIMEOUT = 120
  MSG_CHARS      = 1_200
  TOTAL_CHARS    = 22_000
  MIN_MESSAGES   = 4   # too thin to have learned anything reusable
  MAX_FACTS_KEPT = 8   # take at most this many from one extraction pass

  def perform(conversation_id)
    convo = Conversation.find_by(id: conversation_id)
    return unless convo
    project = convo.project
    return unless project
    return if convo.message_count.to_i < MIN_MESSAGES

    facts = extract_facts(convo)
    facts.first(MAX_FACTS_KEPT).each do |body|
      KnowledgeFact.record!(project: project, body: body, conversation: convo)
    end
  rescue => e
    Rails.logger.error("[extract_facts] #{e.class}: #{e.message}")
  ensure
    # Stamp regardless of outcome so a flaky/empty pass still debounces the next
    # sync — we don't want to retry-storm the CLI on every turn.
    convo&.update_columns(facts_extracted_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  private

  # Returns an array of short fact strings (junk filtered), or [] on any failure.
  def extract_facts(convo)
    raw = run_claude(build_prompt(convo))
    parse_facts(extract_text(raw))
  rescue => e
    Rails.logger.error("[extract_facts] #{e.class}: #{e.message}")
    []
  end

  def build_prompt(convo)
    [
      "From the following Claude CLI coding session, extract 3 to 8 DURABLE, REUSABLE facts",
      "about the codebase or repository — where things live, conventions, architecture, and",
      "gotchas that would help a future session in this same repo skip re-discovery. Examples:",
      "'auth lives in app/services/auth', 'UUID primary keys everywhere', 'e2e tests in spec/e2e',",
      "'run lint with bin/rubocop'. Do NOT include anything session-specific or narrative (what",
      "was done today, bug X was fixed, the user asked for Y).",
      "",
      "Output ONLY a JSON array of short strings (each under 200 chars), nothing else.",
      "If there is nothing durable to learn, output [].",
      "",
      "Session: #{convo.display_title}",
      "",
      "--- TRANSCRIPT ---",
      transcript(convo)
    ].join("\n")
  end

  def transcript(convo)
    who = { "user" => "User", "assistant" => "Claude" }
    out = +""
    convo.conversation_messages.order(:position).each do |m|
      body = m.body.to_s.strip
      next if body.empty?
      body = "#{body[0, MSG_CHARS]}…" if body.length > MSG_CHARS
      line = "#{who[m.role] || m.role}: #{body}\n"
      break if out.length + line.length > TOTAL_CHARS
      out << line
    end
    out.presence || "(empty conversation)"
  end

  # Parse the model's reply into a clean list of fact strings. We require a JSON
  # array (which the prompt asks for explicitly); anything else — prose, a bare
  # object, malformed JSON — yields [] so junk never reaches the store. Tolerates
  # a code-fenced array. Drops blanks and over-long entries (record! also guards).
  def parse_facts(text)
    body = text.to_s.strip.sub(/\A```(?:json)?\s*/, "").sub(/\s*```\z/, "")
    parsed = JSON.parse(body)
    return [] unless parsed.is_a?(Array)

    parsed.map { |x| x.to_s.strip }
          .reject { |x| x.blank? || x.length > KnowledgeFact::MAX_BODY }
  rescue JSON::ParserError
    []
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

  def extract_text(raw)
    parsed = JSON.parse(raw)
    raise "claude returned an error: #{parsed['result']}" if parsed["is_error"]
    parsed["result"].to_s.strip
  rescue JSON::ParserError
    raw.to_s.strip
  end
end
