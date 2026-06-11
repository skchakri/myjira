module UiHelper
  STATUS_CLASS = {
    # task statuses
    "open"             => "pill-quiet",
    "in_progress"      => "pill-accent",
    "implemented"      => "pill-accent",
    "ready_for_test"   => "pill-accent",
    "testing"          => "pill-accent",
    "done"             => "pill-pass",
    "blocked"          => "pill-block",
    # plan statuses
    "draft"            => "pill-quiet",
    "active"           => "pill-accent",
    "archived"         => "pill-quiet",
    # run statuses
    "running"          => "pill-accent",
    "passed"           => "pill-pass",
    "failed"           => "pill-fail",
    "partial"          => "pill-block",
    "aborted"          => "pill-quiet",
    # result statuses
    "pending"          => "pill-quiet",
    "pass"             => "pill-pass",
    "fail"             => "pill-fail",
    "skipped"          => "pill-skip",
    # follow-up statuses
    "resolved"         => "pill-pass",
    "wontfix"          => "pill-quiet",
    # browser relay statuses (in_progress / done / failed already mapped above)
    "queued"           => "pill-quiet",
    "dispatched"       => "pill-accent",
    "needs_input"      => "pill-block",
    "responded"        => "pill-pass",
    "cancelled"        => "pill-quiet",
    # session-launch statuses (pending / failed already mapped above)
    "launching"        => "pill-accent",
    "launched"         => "pill-pass",
    "canceled"         => "pill-quiet"
  }.freeze

  SEVERITY_CLASS = {
    "low"      => "pill-quiet",
    "medium"   => "pill-accent",
    "high"     => "pill-block",
    "critical" => "pill-fail"
  }.freeze

  def status_pill(value)
    klass = STATUS_CLASS[value.to_s] || "pill-quiet"
    content_tag :span, value.to_s.tr("_", " "), class: "pill #{klass}"
  end

  def severity_pill(value)
    klass = SEVERITY_CLASS[value.to_s] || "pill-quiet"
    content_tag :span, value.to_s, class: "pill #{klass}"
  end

  # Glyph for a session highlight bullet ({ "kind" => ... } from Conversation).
  HIGHLIGHT_GLYPH = {
    "commit" => "✓", "edit" => "✎", "test" => "▢",
    "run" => "$", "task" => "✦", "web" => "↗"
  }.freeze
  def highlight_glyph(kind)
    HIGHLIGHT_GLYPH[kind.to_s] || "•"
  end

  # Pill colour for a pull-request state badge (drafts read as quiet).
  def pr_pill_class(state, draft = false)
    return "pill-quiet" if draft
    case state.to_s
    when "open"   then "pill-pass"
    when "merged" then "pill-accent"
    when "closed" then "pill-fail"
    else "pill-quiet"
    end
  end

  def card(title: nil, actions: nil, &block)
    content_tag :section, class: "paper" do
      header_html = if title
        content_tag(:header, class: "flex items-center justify-between px-4 py-2.5 hair-b") do
          content_tag(:span, title, class: "eyebrow") +
            (actions ? content_tag(:div, actions, class: "text-xs text-[color:var(--color-ink-faint)]") : "".html_safe)
        end
      else
        "".html_safe
      end
      header_html + content_tag(:div, capture(&block), class: "p-4")
    end
  end

  # Segmented track: renders pass / fail / block segments in a single bar
  # so you see the mix at a glance, not just percent-done.
  def segmented_track(passed:, failed:, blocked:, total:)
    total = total.to_i
    return content_tag(:div, "", class: "track") if total.zero?
    pct = ->(n) { (n.to_i * 100.0 / total).clamp(0, 100) }
    content_tag :div, class: "flex h-[3px] w-full overflow-hidden rounded-full bg-[color:var(--color-hair-soft)]" do
      [
        content_tag(:span, "", style: "width:#{pct.call(passed)}%; background:var(--color-pass-ink);"),
        content_tag(:span, "", style: "width:#{pct.call(failed)}%; background:var(--color-fail-ink);"),
        content_tag(:span, "", style: "width:#{pct.call(blocked)}%; background:var(--color-block-ink);")
      ].join.html_safe
    end
  end

  # Single-color progress bar (compat with old usage)
  def progress_bar(percent, passed: 0, failed: 0, total: 0)
    cls = if failed.to_i.positive? then "track-fail"
    elsif passed.to_i == total.to_i && total.to_i.positive? then "track-pass"
    else ""
    end
    content_tag :div, class: "track #{cls}" do
      content_tag :span, "", style: "width: #{[ percent.to_f, 100 ].min}%"
    end
  end

  def format_time(t)
    return "—" if t.blank?
    t.strftime("%b %-d, %Y · %H:%M")
  end

  # Readable label for the handful of common cron shapes, else the raw cron.
  COMMON_CRONS = {
    "* * * * *"   => "every minute",
    "*/5 * * * *" => "every 5 min",
    "*/15 * * * *" => "every 15 min",
    "0 * * * *"   => "hourly",
    "0 9 * * *"   => "daily · 09:00",
    "0 18 * * *"  => "daily · 18:00",
    "0 9 * * 1-5" => "weekdays · 09:00",
    "0 0 * * 0"   => "weekly · Sun 00:00",
    "0 0 1 * *"   => "monthly · 1st"
  }.freeze
  def cron_humanize(cron)
    COMMON_CRONS[cron.to_s.strip] || cron.to_s
  end

  # Short relative time — "2h ago", "3d ago", "just now"
  def ago(t)
    return "—" if t.blank?
    secs = (Time.current - t).to_i
    return "just now" if secs < 60
    return "#{secs / 60}m ago"      if secs < 3600
    return "#{secs / 3600}h ago"    if secs < 86_400
    return "#{secs / 86_400}d ago"  if secs < 60 * 86_400
    t.strftime("%b %-d")
  end

  # Health rollup for one project — for sidebar dots and index stats.
  # Memoized per-request so the sidebar's N-client loop stays cheap.
  def client_health(project)
    @client_health_cache ||= {}
    @client_health_cache[project.id] ||= begin
      plan_ids = project.test_plans.pluck(:id)
      latest_per_plan = if plan_ids.any?
        TestRun
          .where(test_plan_id: plan_ids)
          .order(:test_plan_id, started_at: :desc)
          .select("DISTINCT ON (test_plan_id) test_runs.*")
          .to_a
      else
        []
      end
      gaps = project.follow_up_tasks.where(status: %w[open in_progress])
      {
        failing: latest_per_plan.any? { |r| r.failed_count.to_i.positive? || r.status == "failed" },
        blocked: latest_per_plan.any? { |r| r.status == "partial" || r.blocked_count.to_i.positive? },
        critical_gaps: gaps.where(severity: %w[critical high]).count,
        total_gaps: gaps.count,
        plans: plan_ids.size,
        passed:  latest_per_plan.sum { |r| r.passed_count.to_i },
        failed:  latest_per_plan.sum { |r| r.failed_count.to_i },
        blocked_count: latest_per_plan.sum { |r| r.blocked_count.to_i }
      }
    end
  end

  # The copy-paste prompt the user drops into the Claude browser extension to
  # execute a run end-to-end. Contains the run id, env base_url and the two
  # API endpoints the extension needs to push per-case results + complete.
  def browser_extension_prompt(run)
    plan     = run.test_plan
    project  = plan.project
    env      = run.environment
    env_url  = (env&.base_url.presence || project.default_base_url.presence || "(no base url set)")
    api_root = request.base_url
    <<~PROMPT
      Run the following myjira test run end-to-end.

      project : #{project.name} (#{project.slug})
      plan    : #{plan.title}
      run     : #{run.id}
      env     : #{env&.name || "none"} → #{env_url}
      cases   : #{run.total_cases}

      Fetch the cases:
        GET #{api_root}/api/v1/projects/#{project.slug}/test_plans/#{plan.id}/test_cases

      For each case, execute its api_call field against #{env_url}. Then push:
        PATCH #{api_root}/api/v1/test_runs/#{run.id}/results/{test_case_id}
        body: {"status":"pass|fail|blocked|skipped","actual_result":"...","notes":"..."}

      After the last case:
        PATCH #{api_root}/api/v1/test_runs/#{run.id}/complete
        body: {"summary":"one-paragraph rollup"}

      When the run completes, task statuses on linked tasks auto-update
      (pass→done, fail→blocked, partial→testing).
    PROMPT
  end

  # The copy-paste prompt the user drops into the Claude for Chrome chat to act
  # on one relay ticket. Paste it ONCE: it tells the browser to stay on the
  # ticket in a poll loop and auto-execute follow-ups the CLI posts later — so a
  # second instruction never needs another "Kick off".
  def browser_task_prompt(task)
    api_root = request.base_url
    target   = task.target_url.presence
    <<~PROMPT
      You are Claude in Chrome. Work this myjira relay ticket and STAY ON IT until
      it is closed. The CLI/human often posts FOLLOW-UP steps on the SAME ticket
      after you reply — you must pick those up AUTOMATICALLY, with no second
      kick-off. So you run a poll loop, not a one-shot.

      ticket : #{task.title}
      id     : #{task.id}
      #{target ? "open   : #{target}" : "open   : (URL is inside the instructions)"}

      On EVERY post, include a stable id for THIS Chrome chat as
      "browser_session_id" (reuse the same value for the whole ticket).

      WORK LOOP — repeat until the ticket status is "done" or "cancelled":

      1. Read the thread (long-poll; first call omit since, then reuse the cursor):
           GET #{api_root}/api/v1/browser_tasks/#{task.id}?wait=25&since=<cursor>
      2. Find the LATEST instruction aimed at you (a role=cli or role=user turn).
         If you haven't done it yet, do exactly what it says in this browser.
         If there's nothing new, go back to 1 and keep polling.
      3. Blocked or unclear? ASK, then keep polling for the answer:
           POST #{api_root}/api/v1/browser_tasks/#{task.id}/messages
           body: {"role":"browser","kind":"question","body":"<your question>","browser_session_id":"<id>"}
      4. Step done → post the result, then KEEP GOING (do NOT end your turn):
           POST #{api_root}/api/v1/browser_tasks/#{task.id}/messages
           body: {"role":"browser","kind":"result","body":"<what you did + found>",
                  "browser_session_id":"<id>","payload":{"screenshot_url":"<optional>"}}
         Then go back to 1. When the CLI posts a follow-up the ticket flips to
         "in_progress" — that's your cue to act again, automatically.
      5. Stop when status is "done"/"cancelled". If you've posted a result and
         nothing new arrives for ~10 minutes, you may stop — the human can
         re-paste this prompt to wake you.

      result → "responded"; question → "needs_input"; a fresh role=cli instruction
      → "in_progress" (act again). The CLI watches live — no copy-paste back.
    PROMPT
  end

  # Channel-level worker prompt: paste ONCE into Claude for Chrome and it watches
  # the whole relay queue, working every auto-dispatched ticket as it lands — so
  # nobody clicks "Kick off" per ticket. Pairs with auto_kickoff.
  def browser_worker_prompt
    api_root = request.base_url
    <<~PROMPT
      You are Claude in Chrome — the STANDING relay worker for myjira. Stay running
      and handle every relay ticket as it arrives. The human does NOT click "Kick
      off"; tickets are auto-dispatched into your queue.

      WATCH LOOP — repeat indefinitely (re-poll every ~10–15s):

      1. Pull the browser queue (tickets waiting on you, across all projects):
           GET #{api_root}/api/v1/inbox?for=browser
         Each entry is a ticket (status dispatched/in_progress) with an id.
      2. For each ticket, work it end-to-end against its own thread:
           GET #{api_root}/api/v1/browser_tasks/<id>?wait=25&since=<cursor>
         Do the latest role=cli / role=user instruction in this browser.
         Blocked? ASK and keep polling:
           POST #{api_root}/api/v1/browser_tasks/<id>/messages
           body: {"role":"browser","kind":"question","body":"<q>","browser_session_id":"<id>"}
         Done with a step? Post the result, then KEEP watching that ticket for
         follow-ups (the CLI often posts more on the same ticket):
           POST #{api_root}/api/v1/browser_tasks/<id>/messages
           body: {"role":"browser","kind":"result","body":"<did + found>","browser_session_id":"<id>"}
      3. Put a stable "browser_session_id" on every post.
      4. A ticket is finished at status done/cancelled — then return to the queue.

      New tickets appear in the queue on their own (auto-dispatched), so you never
      need a manual kick-off. Just keep the loop running.
    PROMPT
  end

  def playwright_runner_command(run)
    myjira = request.base_url
    <<~CMD.strip
      cd script/playwright_runner
      node index.js --run-id=#{run.id} --myjira=#{myjira} --visible
      # swap --visible for --headless to run without a browser window
    CMD
  end

  def sidebar_clients
    @sidebar_clients ||= Project.clients.order(:name).to_a
  end

  # Distinct, pleasant folder-accent colours. A project's saved `color` wins;
  # otherwise pick deterministically from the slug so each folder is stable and
  # different. Used by the conversation cards (recolour via the gear menu).
  FOLDER_PALETTE = %w[
    #B8502A #2F6F4F #2C5F8A #6B4E9E #9F2D2D
    #1F7A6E #8A5A1E #4A5568 #B5547F #3A4FA0
    #1565A0 #0E7490 #3E7C3E #6B8E23 #C0392B
    #BF6516 #7E57C2 #9B59B6 #C2185B #795548
    #546E7A #37474F #00897B #5D4037 #A03060
  ].freeze

  def project_color(project)
    project.color.presence || FOLDER_PALETTE[project.slug.to_s.sum % FOLDER_PALETTE.size]
  end

  # Counts for the pinned "Browser Tasks" relay row in the sidebar.
  #   :open    — tickets still in flight (queued…responded)
  #   :waiting — tickets needing a CLI/human turn (needs_input/responded)
  def browser_relay_stats
    @browser_relay_stats ||= {
      open: BrowserTask.open.count,
      waiting: BrowserTask.for_cli.count
    }
  end

  # Total captured CLI conversations — for the pinned sidebar "Conversations" row.
  def conversations_total
    @conversations_total ||= Conversation.count
  end
end
