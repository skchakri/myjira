module WorkQueue
  # Plain-words view of an item for the Flow layout: a tone (dot colour), a
  # label, a step on the six-step path, and the filter tags it belongs to.
  #
  # Data sources: the PR (checks, conflicts) and Delivery (batch CI and deploy
  # runs from GitHub Actions), both read from StatusCache. Without them:
  #   testing  = running in the router's "review" phase
  #   ok/Live  = status done (repo has no deploy workflow, or nothing cached yet)
  class Flow
    STEPS = ["Asked", "Planned", "Building", "Review", "Testing together", "Live"].freeze
    FILTERS = [
      ["all", "All"], ["you", "Needs you"], ["answer", "Needs answer"], ["approve", "Needs approval"],
      ["bundle", "Ready to bundle"], ["merge", "Ready to merge"], ["run", "In progress"], ["testing", "Testing / deploying"], ["bad", "Failed"],
      ["wait", "Queued"], ["ok", "Live"], ["open", "Not live yet"], ["closed", "Merged / dropped"]
    ].freeze

    YOUR_PART = {
      "answer" => "Answer the questions above.",
      "approve" => "Approve the plan or ask for changes.",
      "merge" => "Look at the changes and merge the PR.",
      "review" => "Look at the changes; there is no PR to merge yet.",
      "bad" => "Check the log below, then retry or tell the agent what to do.",
      "stalled" => "Resume it, or tell the agent what to do.",
      "bundle" => "Nothing. It ships in one PR with its parent and follow-ups once they are all built.",
      "run" => "Nothing yet. It moves on by itself.",
      "notlive" => "Nothing. It goes live with the next deploy.",
      "wait" => "Nothing. It starts by itself.",
      "ok" => "Nothing.",
      "closed" => "Nothing."
    }.freeze

    # A running item with no sign of life for this long reads "Stalled" instead of "Building".
    STALL_AFTER = 30.minutes

    attr_reader :item, :tone, :label, :step, :tags

    def initialize(item, context = nil)
      @item = item
      @context = context
      @tone, @label, @step, tags, @part = compute
      @tags = item.open? ? ["all", "open", *tags].uniq : tags
    end

    def closed? = tags.include?("closed")
    def stalled? = tags.include?("stalled")

    # Seconds a running item has shown no activity, once past STALL_AFTER; nil otherwise.
    # Activity is the context's view (queue log, transcript file, live runner process);
    # without a context only the queue file's own timestamp is known.
    def stalled_for
      return @stalled_for if defined?(@stalled_for)

      @stalled_for = begin
        at = (@context.last_activity if @context.respond_to?(:last_activity)) || item.updated_at
        idle = at && Time.current - at
        alive = @context.respond_to?(:live_pid?) && @context.live_pid?
        idle if item.status == "running" && !alive && idle && idle >= STALL_AFTER
      end
    end
    def your_part = YOUR_PART.fetch(@part)

    # Queue log lines that say nothing to a person: status arrows, routing picks, worktree paths.
    NOISE = %r{\A(?:→ |Worktree |(?:plan|implement|review|trivial|relay): \S+ / )}
    NOW = { "Planning" => "Planning now.", "Building" => "Building now.", "Testing" => "Testing now." }.freeze

    # One plain line for "What's happening": the summary, else the latest log line a
    # person can read, else what the current phase is doing.
    def happening
      return item.summary if item.summary.present?

      lines = item.log.map { |l| l["text"].to_s.strip }.compact_blank
      now = NOW[label] if item.status == "running"
      now = "No activity since #{(Time.current - stalled_for).strftime('%b %-d %H:%M')}. The session that ran it has probably ended." if stalled?
      return now if now && (lines.empty? || lines.last.match?(NOISE))

      lines.reverse.find { |t| !t.match?(NOISE) } || now || "Nothing recorded yet."
    end

    # How far this item itself is, 0..100: finished phases out of six, plus half a
    # phase while one is running. nil for dropped / folded items (they count nowhere).
    def percent
      return nil if closed?
      return 100 if phase >= PHASES.size

      ((phase + (item.status == "running" ? 0.5 : 0)).fdiv(PHASES.size) * 100).round
    end

    def finished? = percent == 100

    # Failed checks / deploy problem and the CI or deploy step it is on, for "What's happening".
    def failed_checks
      pr = item.open? ? @context&.pr_status : nil
      (Array(pr&.failed_checks) + Array(delivery&.failed)).uniq
    end

    def delivery_note = delivery&.detail

    # Per step: "done", "now-<tone>" or nil (not reached).
    def path
      STEPS.each_index.map do |i|
        if i < step || (i == step && tone == "ok") then "done"
        elsif i == step && tone != "wait" then "now-#{tone}"
        end
      end
    end

    # The work phases shown in "What's happening": plan → build → test → PR → merged → live.
    PHASES = ["Plan", "Build", "Test", "PR", "Merged", "Live"].freeze
    RUN_PHASE = { "plan" => 0, "implement" => 1, "trivial" => 1, "review" => 2 }.freeze

    # Index of the phase the item is on now.
    def phase
      @phase ||= case item.status
      when "done" then delivery&.state.in?(%w[testing deploying not_live deploy_failed]) ? 5 : 6
      when "merged", "dropped" then 0
      when "review" then item.pr.present? ? 4 : 3
      when "running", "blocked" then RUN_PHASE.fetch(@context&.run&.dig("phase").to_s, 1)
      else 0
      end
    end

    # [[name, "done" | "now-<tone>" | nil]] per phase.
    def phases
      PHASES.each_with_index.map do |name, i|
        state = if i < phase then "done"
        elsif i == phase && item.status != "dropped" then "now-#{tone}"
        end
        [name, state]
      end
    end

    def ref
      parts = ["task #{item.n}"]
      parts << "PR ##{item.pr_number}" if item.pr_number
      parts << "branch #{item.branch}" if item.branch.present?
      parts << "bundle of task #{item.bundle_info['root']}" if item.bundle_info["root"]
      parts.join(" · ")
    end

    private

    def compute
      case item.status
      when "merged" then ["wait", item.merged_into ? "Folded into task #{item.merged_into}" : "Folded into another task", 0, %w[closed], "closed"]
      when "dropped" then ["wait", "Dropped", 0, %w[closed], "closed"]
      when "done" then done_state
      else open_state
      end
    end

    def open_state
      return ["you", "Needs your answer", item.status == "review" ? 3 : 1, %w[you answer], "answer"] if item.open_questions.any?
      return ["you", "Needs your approval", 1, %w[you approve], "approve"] if item.awaiting_approval

      case item.status
      when "triage" then ["wait", "Being sorted", 0, %w[wait], "wait"]
      when "queued" then ["wait", "Queued", 0, %w[wait], "wait"]
      when "running" then running_state
      when "blocked" then item.bundle_failed? ? ["bad", "Left out of bundle", 3, %w[bad you], "bad"] : ["bad", "Stuck: needs a look", 2, %w[bad you], "bad"]
      else review_state
      end
    end

    def delivery = @context.respond_to?(:delivery) ? @context.delivery : nil

    def done_state
      case delivery&.state
      when "testing" then ["run", "Testing together", 4, %w[testing], "run"]
      when "deploying" then ["run", "Deploying", 5, %w[testing open], "run"]
      when "not_live" then ["wait", "Merged, not live yet", 5, %w[open], "notlive"]
      when "deploy_failed" then ["bad", "Deploy failed", 5, %w[bad you open], "bad"]
      else ["ok", "Live", 5, %w[ok], "ok"]
      end
    end

    def running_state
      phase = @context&.run&.dig("phase").to_s
      return ["bad", "Stalled: no activity for #{idle_words(stalled_for)}", RUN_STEP.fetch(phase, 2), %w[bad you stalled], "stalled"] if stalled_for

      case @context&.run&.dig("phase")
      when "plan" then ["run", "Planning", 1, %w[run], "run"]
      when "review" then ["run", "Testing", 4, %w[testing], "run"]
      else ["run", "Building", 2, %w[run], "run"]
      end
    end

    def review_state
      return ["wait", "Ready to bundle", 3, %w[bundle], "bundle"] if item.ready_to_bundle? && item.pr.blank?
      return ["you", "Ready for review", 3, %w[you], "review"] if item.pr.blank?

      pr = @context&.pr_status
      return ["bad", "PR has conflicts", 3, %w[bad you], "bad"] if pr&.conflicts?
      return ["bad", "Failed checks", 3, %w[bad you], "bad"] if failed_checks.any?
      return ["run", "Testing together", 4, %w[testing], "run"] if delivery&.state == "testing"

      ["you", bundled_label || "Ready to merge", 3, %w[you merge], "merge"]
    end

    RUN_STEP = { "plan" => 1, "review" => 4 }.freeze

    def idle_words(seconds)
      minutes = (seconds / 60).floor
      return "#{minutes}m" if minutes < 60
      return "#{minutes / 60}h" if minutes < 48 * 60

      "#{minutes / 1440}d"
    end

    def bundled_label = item.bundle_info["pr"] && item.pr_number ? "Bundled → PR ##{item.pr_number}" : nil
  end
end
