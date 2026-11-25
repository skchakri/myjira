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
      ["wait", "Queued"], ["yours", "Yours"], ["ok", "Live"], ["unreleased", "Merged, not live"], ["open", "Open or not live"], ["closed", "Merged / dropped"]
    ].freeze

    YOUR_PART = {
      "answer" => "Answer the questions above.",
      "approve" => "Approve the plan or ask for changes.",
      "merge" => "Look at the changes and merge the PR.",
      "review" => "Look at the changes; there is no PR to merge yet.",
      "children_done" => "Nothing to merge here: every child step shipped in its own PR. Close this task.",
      "bad" => "Check the log below, then retry or tell the agent what to do.",
      "stalled" => "Resume it, or tell the agent what to do.",
      "bundle" => "Nothing. It ships in one PR with its parent and follow-ups once they are all built.",
      "run" => "Nothing yet. It moves on by itself.",
      "notlive" => "Deploy it (Releases, or homey's Ship page) when you are ready; it goes live with the next deploy.",
      "train" => "Nothing. homey's release train tests it in its next batch and merges it when green.",
      "train_failed" => "Fix what failed (see the log below), push to the PR's branch, then retry. homey tries a PR again once it has a new commit.",
      "stacked" => "Merge the branch it went into (its parent pull request) to main. A deploy alone will not ship it.",
      "wait" => "Nothing. It starts by itself.",
      "held" => "Clear some of what is waiting on you in this project and it starts by itself, or start it anyway.",
      "decide" => "Start it or drop it. It is a nice-to-have, so it will not start by itself.",
      "yours" => "Do it, then tick it off. No agent will pick this up.",
      "snoozed" => "Nothing until the snooze ends.",
      "yours_done" => "Nothing. You ticked it off.",
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
        idle if item.status == "running" && !item.yours? && !alive && idle && idle >= STALL_AFTER
      end
    end
    def your_part = YOUR_PART.fetch(@part)

    WAIT_WARN = 1.day
    WAIT_LATE = 3.days

    # When the item started waiting on the person (nil when it is not): the oldest open
    # question, the moment a run went quiet, else when it entered its current status.
    def waiting_since
      return @waiting_since if defined?(@waiting_since)

      @waiting_since = if item.errand?
        item.yours_at || status_since || item.created_at || item.updated_at
      elsif tags.include?("you")
        asked = item.open_questions.filter_map { |q| epoch_ms(q.at) }.min
        asked || (Time.current - stalled_for if stalled?) || status_since || item.updated_at || item.created_at
      end
    end

    def waiting_for = waiting_since && [Time.current - waiting_since, 0].max

    # "12m", "5h 12m", "4d 3h".
    def waiting_words
      seconds = waiting_for or return
      minutes = (seconds / 60).floor
      return "#{minutes}m" if minutes < 60
      return "#{minutes / 60}h #{minutes % 60}m" if minutes < 1440

      "#{minutes / 1440}d #{(minutes % 1440) / 60}h"
    end

    # nil (fresh), "warn" (over a day) or "late" (over three days).
    def waiting_level
      return (item.overdue? ? "late" : ("warn" if item.due_today?)) if item.errand? # an errand nags by its due date, not its age

      seconds = waiting_for or return
      return "late" if seconds >= WAIT_LATE

      "warn" if seconds >= WAIT_WARN
    end

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
      return item.open? ? 0 : 100 if item.yours? # an errand has no agent phases: not done, or done
      return 100 if phase >= PHASES.size
      return steps_percent if item.steps? && phase < STEP_PHASES

      ((phase + (item.status == "running" ? 0.5 : 0)).fdiv(PHASES.size) * 100).round
    end

    def finished? = percent == 100

    # A planned item's steps cover the work phases (Plan, Build, Test): the share of
    # them done, plus half a step for the one in progress, mapped onto that span.
    STEP_PHASES = 3
    def steps_percent
      steps = item.plan_steps
      share = (item.steps_done + (steps.count(&:doing?) * 0.5)).fdiv(steps.size)
      (share * STEP_PHASES.fdiv(PHASES.size) * 100).round
    end

    # Failed checks / deploy problem and the CI or deploy step it is on, for "What's happening".
    def failed_checks
      pr = item.open? ? @context&.pr_status : nil
      (Array(pr&.failed_checks) + Array(delivery&.failed)).uniq
    end

    def delivery_note = delivery&.detail
    def delivery_url = delivery&.url

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
      @phase ||= case item.yours? ? "yours-#{item.open? ? 'open' : item.status}" : item.status
      when "yours-open" then 0
      when "yours-done" then PHASES.size
      when "done" then delivery&.state.in?(%w[testing deploying not_live stacked deploy_failed]) ? 5 : 6
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
      return ["ok", "Done by you", 5, %w[ok], "yours_done"] if item.yours? && item.status == "done"

      case item.status
      when "merged" then ["wait", item.merged_into ? "Folded into task #{item.merged_into}" : "Folded into another task", 0, %w[closed], "closed"]
      when "dropped" then ["wait", "Dropped", 0, %w[closed], "closed"]
      when "done" then done_state
      else open_state
      end
    end

    def open_state
      return yours_state if item.yours?
      return ["you", "Needs your answer", item.status == "review" ? 3 : 1, %w[you answer], "answer"] if item.open_questions.any?
      return ["wait", "Held: waiting for you to catch up", 0, %w[wait held], "held"] if item.held?
      return ["wait", "Suggested: start or drop", 0, %w[wait decide], "decide"] if item.to_decide?
      return ["you", "Needs your approval", 1, %w[you approve], "approve"] if item.awaiting_approval

      case item.status
      when "triage" then ["wait", "Being sorted", 0, %w[wait], "wait"]
      when "queued" then ["wait", "Queued", 0, %w[wait], "wait"]
      when "running" then running_state
      when "blocked" then blocked_state
      else review_state
      end
    end

    # An errand: its own tone ("mine"), never "needs you" / failed / stalled, so it stays
    # out of the agent pipeline's counts. "due" marks the ones the inbox badge counts.
    def yours_state
      if item.snoozed?
        return ["wait", "Snoozed until #{day_words(item.snoozed_until.to_date)}", 0, %w[yours snoozed], "snoozed"]
      end

      label = if item.overdue? then "Yours · overdue #{(Time.zone.today - item.due).to_i}d"
      elsif item.due_today? then "Yours · due today"
      elsif item.due then "Yours · due #{item.due.strftime('%b %-d')}"
      else "Yours"
      end
      ["mine", label, 0, item.due_now? ? %w[yours due] : %w[yours], "yours"]
    end

    # "tomorrow", "Mon" (within a week), else "Nov 28".
    def day_words(date)
      days = (date - Time.zone.today).to_i
      return "tomorrow" if days == 1
      return "later today" if days <= 0

      days < 7 ? date.strftime("%a") : date.strftime("%b %-d")
    end

    def delivery = @context.respond_to?(:delivery) ? @context.delivery : nil

    def done_state
      case delivery&.state
      when "testing" then ["run", "Testing on homey", 4, %w[testing], "run"]
      when "deploying" then ["run", "Deploying", 5, %w[testing open unreleased], "run"]
      when "not_live" then ["wait", delivery.unknown? ? "Deploy result unknown" : "Ready to deploy", 5, %w[open unreleased], "notlive"]
      when "stacked" then ["wait", "Merged into a branch, not on main", 5, %w[open unreleased], "stacked"]
      when "deploy_failed" then ["bad", "Deploy failed", 5, %w[bad you open unreleased], "bad"]
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

    # In review with no PR of its own while every child step is finished.
    def children_done?
      kids = @context.respond_to?(:children) ? @context.children : []
      !item.ready_to_bundle? && ParentCloser.children_done?(kids)
    end

    def review_state
      return ["wait", "Ready to bundle", 3, %w[bundle], "bundle"] if item.ready_to_bundle? && item.pr.blank?
      return ["ok", "All child steps done", 3, %w[children_done], "children_done"] if item.pr.blank? && children_done?
      return ["you", "Ready for review", 3, %w[you], "review"] if item.pr.blank?

      pr = @context&.pr_status
      return ["bad", "PR has conflicts", 3, %w[bad you], "bad"] if pr&.conflicts?
      return ["bad", "Failed checks", 3, %w[bad you], "bad"] if failed_checks.any?
      return ["run", "Testing on homey", 4, %w[testing], "run"] if delivery&.state == "testing"
      return ["run", "Waiting for homey's release train", 4, %w[testing], "train"] if HomeyTrain.batched?(pr&.repo)

      ["you", bundled_label || "Ready to merge", 3, %w[you merge], "merge"]
    end

    def blocked_state
      return ["bad", "Failed on homey's release train", 4, %w[bad you], "train_failed"] if item.bundle_info["train"].present?
      return ["bad", "Left out of bundle", 3, %w[bad you], "bad"] if item.bundle_failed?

      ["bad", "Stuck: needs a look", 2, %w[bad you], "bad"]
    end

    RUN_STEP = { "plan" => 1, "review" => 4 }.freeze

    # Time of the last "→ status" line in the queue log.
    def status_since
      line = item.log.reverse.find { |l| l["text"].to_s.start_with?("→ ") }
      epoch_ms(line && line["at"])
    end

    def epoch_ms(value)
      ms = value.to_i
      Time.zone.at(ms / 1000.0) if ms > 1_000_000_000_000 # anything smaller is not a real timestamp
    end

    def idle_words(seconds)
      minutes = (seconds / 60).floor
      return "#{minutes}m" if minutes < 60
      return "#{minutes / 60}h" if minutes < 48 * 60

      "#{minutes / 1440}d"
    end

    def bundled_label = item.bundle_info["pr"] && item.pr_number ? "Bundled → PR ##{item.pr_number}" : nil
  end
end
