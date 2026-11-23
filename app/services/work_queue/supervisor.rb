module WorkQueue
  # Runs queue items headlessly (bin/work-queue-runner). Takes commands from the
  # Redis list RunState::JOBS, keeps at most MAX_RUNNING Claude processes, and
  # starts queued items as slots free up. Each item gets its own git worktree;
  # phases plan → implement → review run as resumes of one Claude session, each
  # with the model/effort the Router picks.
  class Supervisor
    MAX_RUNNING = ENV.fetch("WORK_QUEUE_MAX_RUNNING", 12).to_i
    MAX_ATTEMPTS = 2
    NEXT_PHASE = { "plan" => "implement", "implement" => "review", "trivial" => nil, "review" => nil, "relay" => nil }.freeze
    PERMISSION_OPTIONS = ["Allow once", "Always allow in this project", "Deny"].freeze

    BUNDLE_EVERY = 30.seconds

    def initialize(store: Store.new, writer: QueueWriter.new, router: Router.new, logger: Rails.logger, bundler: nil)
      @store = store
      @bundler = bundler || Bundler.new(store: store, writer: writer, logger: logger)
      @writer = writer
      @router = router
      @logger = logger
      @threads = {}
      @mutex = Mutex.new
    end

    def start
      @logger.info("[work-queue-runner] up, max #{MAX_RUNNING} concurrent")
      loop do
        _, raw = RunState.redis.blpop(RunState::JOBS, timeout: 1)
        handle(JSON.parse(raw)) if raw
        reap
        fill_slots
        bundle_tick
        heartbeat
      rescue JSON::ParserError
        next
      rescue StandardError => e
        @logger.error("[work-queue-runner] #{e.class}: #{e.message}")
      end
    end

    def handle(job)
      key = job["key"]
      case job["action"]
      when "start" then queue_start(key, job)
      when "answer" then resume_with(key, answer_prompt(key, job))
      when "continue" then resume_with(key, job["text"].to_s)
      when "retry" then queue_start(key, job.merge("attempts" => RunState.get(key)["attempts"].to_i + 1, "phase" => RunState.get(key)["phase"]))
      when "stop" then stop(key)
      when "suggest" then suggest(key, job)
      end
    end

    # Lets the web UI show whether a runner is up and whether relays can work
    # from where it runs (the Claude-in-Chrome bridge is a socket in the host's /tmp).
    def heartbeat
      return if @beat && @beat > 3.seconds.ago

      @beat = Time.current
      RunState.redis.set("#{RunState::PREFIX}:runner", { host: Socket.gethostname, running: running_count, max: MAX_RUNNING,
                                                         chrome_bridge: Dir.glob("/tmp/claude-mcp-browser-bridge-*").any? }.to_json, ex: 10)
    end

    # Ships finished bundles (a root item + its follow-ups) as one PR, off the
    # main loop so merges and test runs never hold up job handling.
    def bundle_tick
      return if @bundled_at && @bundled_at > BUNDLE_EVERY.ago
      return if @bundle_thread&.alive?

      @bundled_at = Time.current
      @bundle_thread = Thread.new do
        Rails.application.executor.wrap { @bundler.tick }
      rescue StandardError => e
        @logger.error("[work-queue-runner] bundler: #{e.class}: #{e.message}")
      end
    end

    def running_count = @mutex.synchronize { @threads.count { |_, t| t.alive? } }

    private

    def queue_start(key, job)
      item = @store.find(key) or return
      RunState.set(key, { "phase" => job["phase"].presence || (job["relay"] ? "relay" : "plan"),
                          "attempts" => job["attempts"].to_i, "mode" => job["relay"] ? "relay" : "build" })
      RunState.redis.rpush("#{RunState::PREFIX}:waiting", key) unless RunState.redis.lrange("#{RunState::PREFIX}:waiting", 0, -1).include?(key)
      @writer.set_status(item.slug, item.n, "queued", log: "Queued to run on the server") if %w[triage blocked].include?(item.status)
    end

    def fill_slots
      while running_count < MAX_RUNNING
        key = RunState.redis.lpop("#{RunState::PREFIX}:waiting") or break
        launch(key)
      end
    end

    def reap = @mutex.synchronize { @threads.delete_if { |_, t| !t.alive? } }

    def launch(key, resume_prompt: nil)
      return if @threads[key]&.alive?

      @threads[key] = Thread.new do
        Rails.application.executor.wrap { run_phase(key, resume_prompt) }
      rescue StandardError => e
        @logger.error("[work-queue-runner] #{key}: #{e.class}: #{e.message}")
      end
    end

    def resume_with(key, text)
      return if text.blank?

      if @threads[key]&.alive?
        @logger.info("[work-queue-runner] #{key} busy; queueing follow-up")
        RunState.set(key, { "followup" => text })
        return
      end
      launch(key, resume_prompt: text)
    end

    def run_phase(key, resume_prompt)
      item = @store.find(key) or return
      run = RunState.get(key)
      phase = run["phase"].presence || "plan"
      cwd = ensure_worktree(item, run) or return
      choice = @router.choose(item, phase, run: run, attempts: run["attempts"].to_i)
      allowed = RunState.project(item.slug)["always_allow"] + Array(JSON.parse(run["allow_once"].presence || "[]"))
      RunState.del_fields(key, "allow_once")
      @writer.update(item.slug, item.n, log: "#{phase}: #{choice.model} / #{choice.effort} (#{choice.source})") do |i|
        i["status"] = "running"
        i["agent"] = run["claude_session"].presence || i["agent"]
      end

      runner = SessionRunner.new(item, key: key, phase: phase, choice: choice, cwd: cwd,
                                 resume: run["claude_session"], prompt: resume_prompt, allowed: allowed)
      result = runner.run(on_spawn: ->(pid) { RunState.set(key, { "pid" => pid }) })
      RunState.del_fields(key, "pid")
      RunState.set(key, { "claude_session" => result.session_id }) if result.session_id
      RunState.record_phase(key, { phase: phase, model: choice.model, effort: choice.effort, reason: choice.reason,
                                   cost_usd: result.cost, input_tokens: result.usage&.dig("input_tokens"),
                                   output_tokens: result.usage&.dig("output_tokens"), ok: !result.error })
      after_phase(item, key, phase, result)
      followup = RunState.get(key)["followup"]
      if followup.present?
        RunState.del_fields(key, "followup")
        run_phase(key, followup)
      end
    end

    def after_phase(item, key, phase, result)
      return if RunState.get(key)["stopped"] == "1" && RunState.del_fields(key, "stopped")

      @writer.update(item.slug, item.n) { |i| i["agent"] = result.session_id } if result.session_id
      if (pr = SessionRunner.pr_in(result.text))
        @writer.update(item.slug, item.n, log: "PR #{pr}") { |i| i["pr"] = pr }
      end

      if result.denials.any?
        RunState.set(key, { "pending_permissions" => result.denials.first(4).to_json })
        @writer.ask(item.slug, item.n, result.denials.first(4).map { |d| { q: "Permission: #{describe(d)}?", options: PERMISSION_OPTIONS } })
      elsif (qs = SessionRunner.questions_in(result.text)).any?
        @writer.ask(item.slug, item.n, qs)
      elsif result.error || !result.exit_ok || result.text.include?("VERDICT: FAIL")
        retry_or_block(item, key, phase, result)
      elsif (nxt = NEXT_PHASE[phase])
        RunState.set(key, { "phase" => nxt })
        run_phase(key, nil)
      else
        bundle = RunState.get(key)["mode"] == "build" && item.pr.blank?
        @writer.update(item.slug, item.n, log: bundle ? "Finished #{phase}; ready to bundle" : "Finished #{phase}") do |i|
          i["status"] = "review"
          if bundle && i["branch"].present?
            i["readyToBundle"] = true
            i.delete("bundle") # a retried item that was left out of a bundle gets bundled again
          end
          i["summary"] = result.text.to_s.gsub(/```.*?```/m, "").strip.last(400)
        end
      end
    end

    def retry_or_block(item, key, phase, result)
      attempts = RunState.get(key)["attempts"].to_i + 1
      if attempts <= MAX_ATTEMPTS
        RunState.set(key, { "attempts" => attempts, "phase" => phase == "review" ? "implement" : phase })
        run_phase(key, "The previous attempt failed: #{result.text.to_s.last(600)}\nFix it and continue.")
      else
        @writer.set_status(item.slug, item.n, "blocked", log: "Stopped after #{attempts - 1} retries: #{result.text.to_s.last(120)}")
      end
    end

    def describe(denial)
      input = denial["tool_input"] || {}
      "#{denial['tool_name']} #{input['command'] || input['file_path'] || input['url']}".strip.truncate(160)
    end

    # Answers to permission questions are mapped back to allowedTools; other
    # answers go to the session as text. Permission answers are batched: the
    # session resumes once, after the last open permission question is answered.
    def answer_prompt(key, job)
      text = job["text"].to_s
      run = RunState.get(key)
      perms = JSON.parse(run["pending_permissions"].presence || "[]")
      return "Answer to your question: #{text}" if perms.empty? || PERMISSION_OPTIONS.exclude?(text)

      denial = perms.find { |d| "Permission: #{describe(d)}?" == job["q"].to_s } || perms.first
      perms.delete(denial)
      notes = Array(JSON.parse(run["permission_notes"].presence || "[]")) << grant(key, denial, text)
      if perms.any?
        RunState.set(key, { "pending_permissions" => perms.to_json, "permission_notes" => notes.to_json })
        return nil
      end

      RunState.del_fields(key, "pending_permissions", "permission_notes")
      "#{notes.join("\n")}\nRetry the steps that were denied (skip the denied ones and find another way, or stop and explain)."
    end

    def grant(key, denial, text)
      rule = PermissionRules.for_denial(denial)
      return "The person denied #{rule}." if text == "Deny"

      if text.start_with?("Always")
        slug = key.split(":").first
        RunState.save_project(slug, "always_allow" => (RunState.project(slug)["always_allow"] + [rule]).uniq)
      else
        once = JSON.parse(RunState.get(key)["allow_once"].presence || "[]")
        RunState.set(key, { "allow_once" => (once + [rule]).uniq.to_json })
      end
      "Permission granted for #{rule}."
    end

    def suggest(key, job)
      item = @store.find(key) or return
      Thread.new do
        Rails.application.executor.wrap { Suggestions.generate(item, job["index"].to_i, job["q"].to_s) }
      rescue StandardError => e
        @logger.error("[work-queue-runner] suggest #{key}: #{e.class}: #{e.message}")
      end
    end

    def stop(key)
      pid = RunState.get(key)["pid"].to_i
      RunState.redis.lrem("#{RunState::PREFIX}:waiting", 0, key)
      item = @store.find(key)
      return unless item

      if pid.positive?
        RunState.set(key, { "stopped" => "1" })
        Process.kill("TERM", -pid)
      end
      @writer.set_status(item.slug, item.n, "blocked", log: "Stopped by you")
    rescue Errno::ESRCH
      nil
    end

    def ensure_worktree(item, run)
      return run["worktree"] if run["worktree"].present? && File.directory?(run["worktree"])

      repo = run["repo"].presence || Workspace.repo_for(item.slug)
      unless repo && File.directory?(File.join(repo, ".git"))
        @writer.set_status(item.slug, item.n, "blocked", log: "No git repo known for #{item.slug}; set the project's repo_path in myjira")
        return
      end
      return repo if run["mode"] == "relay"

      branch = "wq/#{item.n}-#{item.title.parameterize.first(40)}"
      path = "#{repo}-wq-#{item.n}"
      base = %w[main master].find { |b| GitInfo.git(repo, "rev-parse", "--verify", "-q", b).last } || "HEAD"
      GitInfo.git(repo, "worktree", "add", "-b", branch, path, base) unless File.directory?(path)
      GitInfo.git(repo, "worktree", "add", path, branch) unless File.directory?(path)
      return unless File.directory?(path)

      Workspace.match_owner(path, repo)
      RunState.set(item.key, { "worktree" => path, "repo" => repo })
      @writer.update(item.slug, item.n, log: "Worktree #{path}") { |i| i["branch"] = branch }
      path
    end
  end
end
