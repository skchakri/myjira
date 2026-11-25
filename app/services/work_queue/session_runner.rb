require "open3"

module WorkQueue
  # Runs ONE phase of an item as a headless Claude Code process
  # (`claude -p --output-format stream-json`) and streams it into the live log.
  # Follow-ups (answers, permissions, next phase) resume the same Claude
  # session with --resume, each with its own --model / --effort.
  class SessionRunner
    QUESTION_PROTOCOL = <<~TXT.freeze
      You are running headless for the myjira Work Queue; nobody can answer interactive prompts.
      If you need a decision from the person, stop and end your reply with exactly one fenced block:
      ```wq-questions
      [{"q": "question", "options": ["recommended answer", "alternative"]}]
      ```
      Explore the code with the Read, Glob and Grep tools rather than shell pipelines. Scratch files go in /tmp.
      Your working directory is this item's own worktree. Change files only with Edit/Write (never echo or
      redirects). Run git as single plain commands from the working directory, one per call, with no `-C`,
      `cd`, `&&` or pipes: `git add <files>`, `git commit -m "..."`, `git push -u origin HEAD`. Never push
      to main and never force-push.
      Otherwise finish the phase and end with a one-line summary. Never open a PR: the queue bundles this
      item with its parent and follow-ups and opens one PR for all of them.
      If you suggest a follow-up whose work lives in a different repo than this one, say so and give that
      repo's absolute path, so it is filed with repo set (it then ships as its own PR in that repo).
      Mark every follow-up you suggest or file as priority "must" (this item is wrong or incomplete without it)
      or "nice" (an improvement). File at most the must-dos for work to start; a "nice" follow-up is never
      started by you, the person picks those in myjira.
    TXT

    PHASE_PROMPTS = {
      "plan" => "PHASE: plan. Read the codebase and write a short implementation plan for this work item. " \
                "Do not edit files yet. Ask questions only if a decision is genuinely needed.",
      "implement" => "PHASE: implement. Implement the plan in this worktree. Run only the tests for the files you " \
                     "changed, plus lint on those files (the full suite runs once per bundle). Commit (author = the " \
                     "repo's configured user, no co-author lines) and push this branch. Do NOT open a PR.",
      "review" => "PHASE: review. Review the diff of this branch against its base for correctness bugs and missed " \
                  "requirements. Fix small issues and push. End with a line `VERDICT: PASS` or `VERDICT: FAIL - <why>`.",
      "trivial" => "Make this small change, run lint on the files you changed, commit and push this branch. Do NOT open a PR.",
      "relay" => "Use the myjira-relay skill in controller mode (drive Claude-in-Chrome yourself, log to a myjira " \
                 "ticket, ask via the wq-questions block if blocked). Close the Chrome tabs you opened when done."
    }.freeze

    # Bundled items must commit and push their own branch; never main.
    GIT_ALLOWED = ["add", "commit", "push", "status", "diff", "log"].map { |c| "Bash(git #{c}:*)" }.freeze
    # Read-only shell commands, scratch writes under /tmp, and filing plans as myjira docs,
    # so planning never stalls on a prompt nobody can answer.
    RELAY = "#{Dir.home}/.claude/skills/myjira-relay/bin/relay".freeze
    READ_ALLOWED = (%w[ls cat head tail wc grep rg pwd sort uniq diff file stat which].map { |c| "Bash(#{c}:*)" } +
                    ["Bash(git show:*)", "Bash(git branch:*)", "Bash(git rev-parse:*)", "Read", "Glob", "Grep",
                     "Write(//tmp/**)", "Edit(//tmp/**)", "Bash(#{RELAY} doc:*)",
                     "Bash(~/.claude/skills/myjira-relay/bin/relay doc:*)"]).freeze
    GIT_DENIED = ["Bash(git push origin main:*)", "Bash(git push origin HEAD:main:*)", "Bash(git push -f:*)",
                  "Bash(git push --force:*)"].freeze

    Result = Struct.new(:session_id, :text, :error, :cost, :usage, :denials, :exit_ok, keyword_init: true)

    attr_reader :pid

    def initialize(item, key:, phase:, choice:, cwd:, resume: nil, prompt: nil, allowed: [])
      @item = item
      @key = key
      @phase = phase
      @choice = choice
      @cwd = cwd
      @resume = resume
      @prompt = prompt
      @allowed = allowed
      @parser = Transcript.new
    end

    def command
      cmd = ["claude", "-p", "--output-format", "stream-json", "--verbose", "--model", @choice.model,
             "--effort", @choice.effort, "--permission-mode", "acceptEdits", "--permission-prompts", "none",
             "--append-system-prompt", QUESTION_PROTOCOL]
      cmd += ["--allowedTools", *GIT_ALLOWED, *READ_ALLOWED, *@allowed]
      cmd += ["--disallowedTools", *GIT_DENIED]
      cmd += ["--resume", @resume] if @resume.present?
      cmd
    end

    def prompt
      return @prompt if @prompt.present? && @resume.present?

      "#{PHASE_PROMPTS.fetch(@phase)}\n\nWork item ##{@item.n}: #{@item.title}\n\n#{@item.description}\n#{@prompt}".strip
    end

    # Blocks until the process exits. on_spawn receives the pid (for Stop).
    def run(on_spawn: nil)
      emit_note("Phase #{@phase} · #{@choice.model} · effort #{@choice.effort} — #{@choice.reason}", kind: "phase")
      result = Result.new(denials: [], exit_ok: false)
      Open3.popen2(*command, chdir: @cwd, pgroup: true) do |stdin, stdout, wait|
        @pid = wait.pid
        on_spawn&.call(@pid)
        stdin.write(prompt)
        stdin.close
        stdout.each_line { |line| handle(line, result) }
        result.exit_ok = wait.value.success?
      end
      missing_result(result)
    rescue SystemCallError => e
      emit_note("Could not start claude: #{e.message}", kind: "error")
      result.tap { |r| r.error = true }
    end

    # The process ended with no result event (killed, or it exited before its output
    # was read): a failed phase, so it is retried instead of passing as finished.
    def missing_result(result)
      return result unless result.text.nil?

      emit_note("Claude exited without a final result; treating this phase as failed", kind: "error")
      result.tap { |r| r.error = true }
    end

    def handle(line, result)
      d = JSON.parse(line)
      case d["type"]
      when "system"
        result.session_id ||= d["session_id"]
      when "user", "assistant"
        entries = @parser.parse_line(line)
        RunState.append_stream(@key, { "line" => line })
        Broadcaster.run_entries(@key, entries)
      when "result"
        result.session_id = d["session_id"] || result.session_id
        result.text = d["result"].to_s
        result.error = d["is_error"] == true
        result.cost = d["total_cost_usd"].to_f
        result.usage = d["usage"] || {}
        result.denials = Array(d["permission_denials"])
      end
    rescue JSON::ParserError
      nil
    end

    def emit_note(text, kind: "phase")
      entry = Transcript::Entry.new(kind: kind, body: text, at: Time.current.iso8601)
      RunState.append_stream(@key, { "note" => text, "kind" => kind })
      Broadcaster.run_entries(@key, [entry])
    end

    def self.questions_in(text)
      block = text.to_s[/```wq-questions\s*(.+?)```/m, 1]
      return [] unless block

      Array(JSON.parse(block)).filter_map { |q| { q: q["q"].to_s, options: Array(q["options"]).map(&:to_s) } if q.is_a?(Hash) && q["q"].present? }
    rescue JSON::ParserError
      []
    end

    def self.pr_in(text) = text.to_s[%r{https://github\.com/[\w.-]+/[\w.-]+/pull/\d+}]
  end
end
