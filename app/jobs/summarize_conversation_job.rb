require "open3"
require "json"
require "timeout"

# Produces a short, spoken-friendly summary of a captured CLI conversation by
# shelling out to the local `claude` CLI (same pattern as HumanizeThreadJob).
# The result is persisted and streamed into the conversation's "Spoken summary"
# panel, where the browser reads it aloud via the Web Speech API.
class SummarizeConversationJob < ApplicationJob
  queue_as :default

  CLAUDE_TIMEOUT = 120
  MSG_CHARS      = 1_200
  TOTAL_CHARS    = 22_000

  def perform(conversation_id)
    convo = Conversation.find(conversation_id)
    convo.update!(summary: summarize(convo), summarized_at: Time.current)
    broadcast(convo)
  rescue => e
    Rails.logger.error("[summarize] #{e.class}: #{e.message}")
    convo ||= Conversation.find_by(id: conversation_id)
    return unless convo
    convo.update(summary: "Couldn't summarize this conversation: #{e.message}", summarized_at: Time.current)
    broadcast(convo)
  end

  private

  def summarize(convo)
    extract_text(run_claude(build_prompt(convo))).presence || "No summary was produced."
  end

  def build_prompt(convo)
    [
      "Summarize the following Claude CLI coding session for someone LISTENING to it read aloud.",
      "Plain spoken English, 4 to 7 short sentences. No markdown, no code, no bullet points, no",
      "headings or symbols — a text-to-speech voice will read it. Cover what the session was about,",
      "what got done, and where it ended. Output ONLY the summary text.",
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

  def broadcast(convo)
    Turbo::StreamsChannel.broadcast_update_to(
      [convo, :messages],
      target: "conversation_summary_#{convo.id}",
      partial: "conversations/summary_content",
      locals: { conversation: convo }
    )
  end
end
