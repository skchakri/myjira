module WorkQueue
  # Sends queue actions to the CLI session that owns the item, over the existing
  # myjira command channel (SessionCommand → myjira-listen long-poll). The
  # work-queue mod stays the only writer of the queue JSON.
  #
  # When the owning session isn't listening, nothing is sent: the result carries
  # a `/itemN …` line the person can paste into any CLI session in that project
  # (the mod's own reply command).
  class Dispatcher
    Result = Struct.new(:sent, :command, :copy, :reason, :launch, :duplicate, keyword_init: true)
    PROTOCOL_HINT = "Use the mcp__work-queue__queue tool for every queue change (never edit the JSON). One task is ONE " \
                    "item: never file follow-up or child items. If the work is big, plan it as 2-5 coarse steps on this item " \
                    "(op \"update\" with steps: [{title, status: todo|doing|done}], browser: true on a step that needs Chrome) " \
                    "and tick them off as you go. Ask questions on the item itself (op \"update\" with ask). Ship one PR, then " \
                    "status \"review\" with the pr.".freeze

    def initialize(item)
      @item = item
    end

    def conversation
      @conversation ||= Conversation.find_by(session_id: @item.session) if @item.session.present?
    end

    def listening? = conversation&.listening? || false

    def run_now
      text = if @item.awaiting_approval
        "Approve and start item ##{@item.n} (#{@item.title}) now"
      else
        "Start item ##{@item.n} (#{@item.title}) now"
      end
      deliver(
        "#{text}, in parallel with whatever is running (Run now from the myjira Work Queue; this overrides the " \
        "max-running limit for this one item). Spawn its background worktree Agent per the queue protocol, then " \
        "op \"update\" n #{@item.n} with status \"running\", agent and branch.#{follow_up_note}",
        copy: "/item#{@item.n} go — start now"
      )
    end

    # "Resume" on a stalled item: no activity for a while, its agent has probably ended.
    def resume
      deliver(
        "Item ##{@item.n} (#{@item.title}) is marked running but has shown no activity for a while (Resume from the " \
        "myjira Work Queue). Check its agent (#{@item.agent || 'none'}): if it is still working, log a one-line status " \
        "with op \"update\" n #{@item.n}; if it ended, continue the work with SendMessage or a new worktree Agent and " \
        "update the queue.#{follow_up_note}",
        copy: "/item#{@item.n} resume — it stalled"
      )
    end

    def answer(index, text)
      q = @item.questions[index]
      deliver(
        "Answer for item ##{@item.n} (#{@item.title}), question #{index + 1}: \"#{q&.q}\"\nAnswer: #{text}\n" \
        "Record it with op \"update\" n #{@item.n} (answer, in open-question order), set status \"running\", log " \
        "\"Answered from myjira: #{text.truncate(80)}\", and pass the answer to its agent (#{@item.agent || 'none yet'}) " \
        "with SendMessage, or start it if it was waiting.",
        copy: "/item#{@item.n} #{text}"
      )
    end

    def instruct(text)
      deliver("Instruction for item ##{@item.n} (#{@item.title}): #{text}\nBrief its agent (#{@item.agent || 'none'}) " \
              "with SendMessage, or start it, and update the queue.", copy: "/item#{@item.n} #{text}")
    end

    def merge_into(target_n, others)
      list = others.map { |n| "##{n}" }.join(", ")
      deliver("Group these work-queue items into ##{target_n}: #{list}. For each, op \"update\" with n and " \
              "mergeInto #{target_n}; if ##{target_n}'s agent is running, SendMessage it the folded requirements.",
              copy: "Merge items #{list} into ##{target_n} (op update mergeInto #{target_n})")
    end

    def pr_merged(prs)
      deliver("PR(s) #{prs.join(', ')} for item ##{@item.n} were squash-merged from myjira. Set the item(s) to " \
              "status \"done\" with a log line.", copy: "/item#{@item.n} PR merged, mark done")
    end

    # "Run in Chrome": the item's next step needs a real browser. The headless
    # runner has no Claude-in-Chrome tools, so this goes to the owning CLI when it
    # listens, else to a fresh interactive `claude --chrome` session spawned by the
    # host launcher daemon in the item's repo. Never silent: with neither path the
    # result carries the reason and a copy command. A launch still starting or
    # running for the item is returned as is (duplicate: true), never queued twice.
    # The check and the queue run under a short per-item Redis lock, so a second
    # near-simultaneous click gets the duplicate result too (its launch may be nil
    # when the first click has not finished queueing yet).
    def run_in_chrome
      ChromeRun.exclusive(@item) { chrome_run } ||
        Result.new(sent: true, launch: ChromeRun.active_launch(RunState.get(@item.key), key: @item.key), duplicate: true)
    end

    CHROME_COPY = "run this item's browser step now in Chrome (myjira-relay controller mode)".freeze

    def chrome_instruction
      step = @item.browser_step
      "Run the browser step of work-queue item ##{@item.n} (#{@item.title})#{" — plan step \"#{step.title}\"" if step} " \
        "now in Chrome (Run in Chrome from the " \
        "myjira Work Queue). Use the myjira-relay skill (~/.claude/skills/myjira-relay) in controller mode: drive " \
        "Claude-in-Chrome yourself with the mcp__claude-in-chrome tools, log progress to a myjira ticket with the relay " \
        "CLI, run `relay blocked` before asking if a login or approval is needed, and close every tab you opened when " \
        "done. Then op \"update\" n #{@item.n} with a log line and summary of what happened in the browser" \
        "#{step ? ", and pass steps with \"#{step.title}\" set to status \"done\" (keep the other steps as they are)" : ''}." \
        "\nItem details:\n#{@item.description.to_s.truncate(2000)}"
    end

    private

    def chrome_run
      active = ChromeRun.active_launch(RunState.get(@item.key), key: @item.key)
      return Result.new(sent: true, launch: active, duplicate: true) if active

      body = chrome_instruction
      copy = "/item#{@item.n} #{CHROME_COPY}"
      return deliver(body, copy: copy).tap { |r| ChromeRun.sent!(@item) if r.sent } if listening?

      repo = @item.repo.presence || Workspace.repo_for(@item.slug)
      # for_repo_path: an item whose repo is a worktree launches under the parent repo's project.
      project = Project.for_repo_path(repo) if repo
      reasons = [listen_reason]
      reasons << "no myjira project has repo_path #{repo || "for #{@item.slug}"}" unless project
      reasons << "the session launcher daemon isn't polling (start myjira-session-launcher.service)" unless SessionLaunch.launcher_alive?
      return Result.new(sent: false, copy: copy, reason: reasons.join("; ")) if reasons.size > 1

      launch = SessionLaunch.queue!(project: project, prompt: body, repo_path: repo, chrome: true, permission_mode: "auto",
                                    source: "work-queue", title: "Chrome: ##{@item.n} #{@item.title}", work_item_key: @item.key)
      ChromeRun.remember(@item, launch)
      Result.new(sent: true, launch: launch)
    end

    def listen_reason = conversation ? "CLI session #{@item.session.to_s.first(8)} isn't listening" : "no live CLI session owns this item"

    # Legacy child items (filed before one-item-per-task) still ship in their parent's PR.
    def follow_up_note
      return "" if @item.parent.blank?

      " It is a legacy child of ##{@item.parent}: commit and push its own branch only and do NOT open a PR; " \
        "it ships in ##{@item.parent}'s PR. Do not file any further items."
    end

    def deliver(body, copy:)
      unless listening?
        return Result.new(sent: false, copy: copy, reason: listen_reason)
      end

      cmd = conversation.session_commands.create!(body: "[work-queue] #{body}\n#{PROTOCOL_HINT}", source: "work-queue")
      Result.new(sent: true, command: cmd)
    end
  end
end
