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
    "cancelled"        => "pill-quiet"
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
  # on one relay ticket. It points the browser at the ticket's JSON, tells it to
  # follow the instructions, post results back, and ask questions if anything is
  # unclear — all against the same thread the CLI is watching.
  def browser_task_prompt(task)
    api_root = request.base_url
    target   = task.target_url.presence
    <<~PROMPT
      You are Claude in Chrome. Execute one myjira relay ticket end-to-end.

      ticket : #{task.title}
      id     : #{task.id}
      #{target ? "open   : #{target}" : "open   : (URL is inside the instructions)"}

      1. Read the full thread + instructions:
           GET #{api_root}/api/v1/browser_tasks/#{task.id}
      2. Do exactly what the latest instructions say, in this browser.
      3. If anything is unclear or blocked, ASK — post a question and stop:
           POST #{api_root}/api/v1/browser_tasks/#{task.id}/messages
           body: {"role":"browser","kind":"question","body":"<your question>"}
           Then poll for the answer (the CLI is watching this same thread):
           GET #{api_root}/api/v1/browser_tasks/#{task.id}?wait=25&since=<cursor>
      4. Post progress as you go (optional):
           POST .../messages  body: {"role":"browser","kind":"message","body":"<update>"}
      5. When finished, post the result and close it:
           POST #{api_root}/api/v1/browser_tasks/#{task.id}/messages
           body: {"role":"browser","kind":"result","body":"<what you did + what you found>",
                  "payload":{"screenshot_url":"<optional>","data":<optional>}}

      kind=result flips the ticket to "responded"; kind=question flips it to
      "needs_input". The CLI sees both live — no copy-paste back.
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
    @sidebar_clients ||= Project.order(:name).to_a
  end
end
