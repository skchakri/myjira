module WorkQueue
  # Runs queue items headlessly (bin/work-queue-runner). Takes commands from the
  # Redis list RunState::JOBS, keeps at most MAX_RUNNING Claude processes, and
  # starts queued items as slots free up. Each item gets its own git worktree;
  # phases plan → implement → review run as resumes of one Claude session, each
  # with the model/effort the Router picks.
  class Supervisor
    MAX_RUNNING = ENV.fetch("WORK_QUEUE_MAX_RUNNING", 4).to_i
    MAX_ATTEMPTS = 2
    NEXT_PHASE = { "plan" => "implement", "implement" => "review", "trivial" => nil, "review" => nil, "relay" => nil }.freeze
    PERMISSION_OPTIONS = ["Allow once", "Always allow in this project", "Deny"].freeze
    # Safe-shaped commands (read / test / lint) suggest the lasting answer first.
    SAFE_PERMISSION_OPTIONS = ["Always allow in this project", "Allow once", "Deny"].freeze
    # A command allowed once this many times in a project becomes a rule by itself.
    AUTO_RULE_AFTER = 2
    # Resumes in a row that were granted without asking, before the person is asked anyway.
    MAX_AUTO_GRANTS = 4

    BUNDLE_EVERY = 30.seconds
    BACKTRACE_LINES = 5
    # A phase whose process ended without a final result event has no text to quote.
    NO_RESULT = "Claude exited without a final result (its output was cut off)".freeze

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
        _, raw = jobs_redis.blpop(RunState::JOBS, timeout: 1)
        handle(JSON.parse(raw)) if raw
        reap
        fill_slots
        bundle_tick
        release_held
        heartbeat
      rescue JSON::ParserError
        next
      rescue StandardError => e
        log_error("loop", e)
      end
    end

    # The blocking pop gets a connection of its own. On the shared one it holds the
    # client's lock for its whole timeout, so every Redis write from the item threads
    # (each stream line, each run-state change) waits behind it; a session's output
    # then backs up in its pipe and Claude exits before its final result is read.
    def jobs_redis = @jobs_redis ||= Redis.new(url: Broadcaster.redis_url)

    # Class, message and the first few backtrace lines, so the error can be located.
    def log_error(what, error)
      trace = Array(error.backtrace).first(BACKTRACE_LINES).map { |l| "\n    #{l}" }.join
      @logger.error("[work-queue-runner] #{what}: #{error.class}: #{error.message}#{trace}")
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
      when "bundle" then bundle_now(key)
      end
    end

    # "Ready for PR": ship this item's bundle now with whatever members are ready.
    def bundle_now(key)
      Thread.new do
        Rails.application.executor.wrap { @bundler.ship_now(key) }
      rescue StandardError => e
        log_error("bundle #{key}", e)
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
        log_error("bundler", e)
      end
    end

    # Items held for a project's daily budget start once the project is under it again
    # (a new day, or a raised budget).
    def release_held
      return if @held_at && @held_at > 1.minute.ago

      @held_at = Time.current
      RunState.held_slugs.each do |slug|
        next if RunState.over_budget?(slug)

        RunState.held(slug).each do |key|
          run = RunState.get(key)
          queue_start(key, { "phase" => run["phase"], "attempts" => run["attempts"], "relay" => run["mode"] == "relay" })
        end
      end
    end

    def running_count = @mutex.synchronize { @threads.count { |_, t| t.alive? } }

    private

    def queue_start(key, job)
      item = @store.find(key) or return
      return refuse_errand(item) if item.errand?

      RunState.set(key, { "phase" => job["phase"].presence || (job["relay"] ? "relay" : "plan"),
                          "attempts" => job["attempts"].to_i, "mode" => job["relay"] ? "relay" : "build" })
      return if hold_for_budget(item, key, job)

      RunState.redis.rpush("#{RunState::PREFIX}:waiting", key) unless RunState.redis.lrange("#{RunState::PREFIX}:waiting", 0, -1).include?(key)
      @writer.set_status(item.slug, item.n, "queued", log: "Queued to run on the server") if %w[triage blocked].include?(item.status)
    end

    # An errand is the person's own to do: no agent runs it, whoever asked for the start.
    def refuse_errand(item)
      @writer.update(item.slug, item.n, log: "Not started: this is an errand for you (Yours). Hand it to an agent first.")
    end

    # True when the project has spent today's budget and this start was not forced (Run now).
    def hold_for_budget(item, key, job)
      if job["force"].present? || !RunState.over_budget?(item.slug)
        RunState.release(item.slug, key)
        return false
      end

      RunState.hold(item.slug, key)
      spent = format("%.2f", Costs.today(item.slug))
      budget = format("%.2f", RunState.daily_budget(item.slug))
      @writer.update(item.slug, item.n, log: "Daily budget reached ($#{spent} of $#{budget} today): waits until tomorrow, or press Run now") do |i|
        i["status"] = "queued" if %w[triage blocked].include?(i["status"])
      end
      true
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
        log_error(key, e)
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
      allowed = PermissionRules.allowed_for(item.slug, run["repo"].presence || cwd) + Array(JSON.parse(run["allow_once"].presence || "[]"))
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

      if (steps = SessionRunner.steps_in(result.text)).any?
        @writer.update(item.slug, item.n, log: "Plan: #{steps.size} steps") { |i| i["steps"] = steps }
      end

      RunState.del_fields(key, "auto_grants") if result.denials.empty?
      if result.denials.any?
        handle_denials(item, key, result.denials.first(4))
      elsif (qs = SessionRunner.questions_in(result.text)).any?
        @writer.ask(item.slug, item.n, qs)
      elsif result.error || !result.exit_ok || result.text.nil? || result.text.include?("VERDICT: FAIL")
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
      why = result.text.presence || NO_RESULT
      if attempts <= MAX_ATTEMPTS
        RunState.set(key, { "attempts" => attempts, "phase" => phase == "review" ? "implement" : phase })
        run_phase(key, "The previous attempt failed: #{why.last(600)}\nFix it and continue.")
      else
        @writer.set_status(item.slug, item.n, "blocked", log: "Stopped after #{attempts - 1} retries: #{why.last(120)}")
      end
    end

    # Denied commands the project's packs and rules already cover are granted
    # without asking (by the exact text Claude ran, wrappers included); only the
    # rest become questions. All covered: the session resumes straight away.
    def handle_denials(item, key, denials)
      run = RunState.get(key)
      cover = PermissionRules.cover_for(item.slug, run["repo"].presence || run["worktree"])
      streak = run["auto_grants"].to_i
      granted, ask = denials.partition { |d| streak < MAX_AUTO_GRANTS && auto_grantable?(d, cover) }
      notes = granted.map { |d| auto_grant(item, d) }

      if ask.empty?
        RunState.set(key, { "auto_grants" => streak + 1 })
        return run_phase(key, "#{notes.join("\n")}\nRetry the steps that were denied.")
      end

      RunState.set(key, { "pending_permissions" => ask.to_json, "permission_notes" => notes.to_json, "auto_grants" => 0 })
      @writer.ask(item.slug, item.n, ask.map { |d| { q: "Permission: #{describe(d)}?", options: permission_options(d) } })
    end

    def auto_grantable?(denial, cover)
      return false unless denial["tool_name"] == "Bash"

      cmd = denial.dig("tool_input", "command").to_s
      PermissionRules.covered?(cmd, cover) && PermissionRules.literal_rules(cmd).present?
    end

    def auto_grant(item, denial)
      rules = PermissionRules.literal_rules(denial.dig("tool_input", "command").to_s)
      remember_literal(item.slug, rules)
      @writer.update(item.slug, item.n, log: "Allowed without asking (covered by this project's rules): #{describe(denial).truncate(100)}")
      "Permission granted for #{rules.join(', ')}."
    end

    # Exact-text rules for wrapped forms of commands the project already allows.
    def remember_literal(slug, rules)
      RunState.save_project(slug, "auto_allow" => (Array(RunState.project(slug)["auto_allow"]) + rules).uniq.last(300))
    end

    def permission_options(denial)
      safe = denial["tool_name"] == "Bash" && PermissionRules.safe?(denial.dig("tool_input", "command").to_s)
      safe ? SAFE_PERMISSION_OPTIONS : PERMISSION_OPTIONS
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

      slug = key.split(":").first
      cmd = denial["tool_name"] == "Bash" ? denial.dig("tool_input", "command").to_s : nil
      # The rule as Claude Code will match it: the raw text, wrappers included.
      literal = cmd && !PermissionRules.destructive?(cmd) ? Array(PermissionRules.literal_rules(cmd)) : []
      if text.start_with?("Always")
        RunState.save_project(slug, "always_allow" => (RunState.project(slug)["always_allow"] + [rule]).uniq)
        remember_literal(slug, literal) if literal.any?
      else
        once = JSON.parse(RunState.get(key)["allow_once"].presence || "[]")
        RunState.set(key, { "allow_once" => (once + [rule] + literal).uniq.to_json })
        count_allow_once(key, slug, rule, cmd)
      end
      "Permission granted for #{rule}."
    end

    # The same command allowed once twice in a project: stop asking.
    def count_allow_once(key, slug, rule, cmd)
      return if cmd.nil? || PermissionRules.destructive?(cmd)

      project = RunState.project(slug)
      return if project["always_allow"].include?(rule)

      counts = (project["allow_counts"] || {}).merge(rule => (project["allow_counts"] || {})[rule].to_i + 1)
      if counts[rule] >= AUTO_RULE_AFTER
        counts.delete(rule)
        RunState.save_project(slug, "always_allow" => (project["always_allow"] + [rule]).uniq, "allow_counts" => counts)
        @writer.update(slug, key.split(":").last.to_i, log: "Now always allowed in this project: #{rule}")
      else
        RunState.save_project(slug, "allow_counts" => counts)
      end
    end

    def suggest(key, job)
      item = @store.find(key) or return
      Thread.new do
        Rails.application.executor.wrap { Suggestions.generate(item, job["index"].to_i, job["q"].to_s) }
      rescue StandardError => e
        log_error("suggest #{key}", e)
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
      if run["worktree"].present? && File.directory?(run["worktree"])
        link_shared(run["repo"], run["worktree"])
        return run["worktree"]
      end

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
      link_shared(repo, path)
      RunState.set(item.key, { "worktree" => path, "repo" => repo })
      @writer.update(item.slug, item.n, log: "Worktree #{path}") { |i| i["branch"] = branch }
      path
    end

    # .env, credential keys, built assets and node_modules are git-ignored, so a new
    # worktree lacks them and its tests cannot boot. Linked in from the main checkout.
    def link_shared(repo, path)
      ProjectEnv.link_shared(repo, path) if repo.present? && repo != path
    rescue SystemCallError => e
      Rails.logger.warn("[work-queue] #{path}: could not link shared files: #{e.message}")
    end
  end
end
