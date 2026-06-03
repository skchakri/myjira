require "open3"
require "json"
require "timeout"

# Summarizes a BrowserTask relay thread into a warm, plain-English digest by
# shelling out to the local `claude` CLI (Claude Code, already authenticated via
# the Max subscription — same pattern as the Playwright runner). The result is
# persisted on the task and streamed into the bottom-right "Humanize" panel.
class HumanizeThreadJob < ApplicationJob
  queue_as :default

  CLAUDE_TIMEOUT = 120  # seconds
  MSG_CHARS      = 2_000 # per-message cap fed to the model
  TOTAL_CHARS    = 24_000 # transcript cap overall

  def perform(task_id)
    task = BrowserTask.find(task_id)
    summary = summarize(task)
    task.update!(humanized_summary: summary, humanized_at: Time.current)
    broadcast(task)
  rescue => e
    Rails.logger.error("[humanize] #{e.class}: #{e.message}")
    task ||= BrowserTask.find_by(id: task_id)
    return unless task
    task.update(humanized_summary: "⚠️ Couldn't humanize this thread: #{e.message}", humanized_at: Time.current)
    broadcast(task)
  end

  private

  def summarize(task)
    raw = run_claude(build_prompt(task))
    extract_text(raw).presence || "(no summary returned)"
  end

  def build_prompt(task)
    [
      "You are summarizing a work thread from \"myjira\", a relay channel where a Claude CLI",
      "coding assistant, a Claude-in-Chrome browser assistant, and a human collaborate on one task.",
      "",
      "Rewrite the conversation below as a warm, clear, plain-English summary a busy human can skim.",
      "- Open with a one-sentence **TL;DR** of what this thread was about and where it landed.",
      "- Then a short bulleted **timeline** of what actually happened, in human terms — no raw queries,",
      "  no log dumps, no jargon walls. Translate the technical bits into what they mean.",
      "- Call out, if present: any **open question**, the key **result/finding**, and the **next step**.",
      "- Keep it under ~200 words. Friendly, natural tone. Plain text / light markdown only.",
      "- Output ONLY the summary — no preamble like \"Here is the summary\".",
      "",
      "Task title: #{task.title}",
      "Current status: #{task.status}",
      "",
      "--- THREAD ---",
      transcript(task)
    ].join("\n")
  end

  def transcript(task)
    who = { "cli" => "Claude CLI", "browser" => "Claude-in-Chrome", "user" => "Human", "system" => "myjira" }
    out = +""
    task.browser_messages.order(:created_at).each do |m|
      body = m.body.to_s.strip
      body = "#{body[0, MSG_CHARS]}… (truncated)" if body.length > MSG_CHARS
      line = "[#{who[m.role] || m.role} · #{m.kind} · #{m.created_at.strftime('%b %-d %-l:%M %p')}]\n#{body}\n\n"
      break if out.length + line.length > TOTAL_CHARS
      out << line
    end
    out.presence || "(empty thread)"
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

  # `--output-format json` wraps the answer in an envelope: {"result":"…","is_error":false}.
  # Fall back to the raw text if it isn't valid JSON.
  def extract_text(raw)
    parsed = JSON.parse(raw)
    raise "claude returned an error: #{parsed['result']}" if parsed["is_error"]
    parsed["result"].to_s.strip
  rescue JSON::ParserError
    raw.to_s.strip
  end

  def broadcast(task)
    Turbo::StreamsChannel.broadcast_update_to(
      [task, :messages],
      target: "humanize_content_#{task.id}",
      partial: "browser_tasks/humanize_content",
      locals: { task: task }
    )
  end
end
