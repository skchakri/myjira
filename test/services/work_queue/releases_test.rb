require "test_helper"

class WorkQueueReleasesTest < ActionDispatch::IntegrationTest
  APP = "me/app".freeze
  LIB = "me/lib".freeze
  BARE = "me/bare".freeze

  setup do
    @dir = Dir.mktmpdir("wq")
    @old = ENV["WORK_QUEUE_DIR"]
    ENV["WORK_QUEUE_DIR"] = @dir
    @redis = WorkQueue::RunState.redis
    @redis.scan_each(match: "#{WorkQueue::RunState::PREFIX}:*") { |k| @redis.del(k) }
    now = (Time.now.to_f * 1000).to_i
    write("home-me-app", [
      done(1, "Parent", pr(APP, 10), now, bundle: { root: 1, pr: pr(APP, 10) }),
      done(2, "Child in the bundle", pr(APP, 10), now, parent: 1, bundle: { root: 1, pr: pr(APP, 10) }),
      done(3, "Already live", pr(APP, 11), now),
      done(4, "Follow-up in another repo", pr(LIB, 3), now, parent: 1, repo: "/home/me/lib"),
      done(5, "Closed, not merged", pr(APP, 12), now),
      done(6, "Never looked up", pr(APP, 13), now),
      { n: 7, title: "Still open", status: "review", pr: pr(APP, 14), questions: [], log: [], updatedAt: now },
      done(8, "Merged into a feature branch", pr(APP, 16), now)
    ])
    cache(pr(APP, 16), "MERGED", "stacked")
    write("home-me-other", [done(1, "Other project, same repo", pr(APP, 15), now),
                            done(2, "No workflow repo", pr(BARE, 1), now)])
    cache(pr(APP, 10), "MERGED", "not_live")
    cache(pr(APP, 11), "MERGED", "live")
    cache(pr(LIB, 3), "MERGED", "deploy_failed")
    cache(pr(APP, 12), "CLOSED", nil)
    cache(pr(APP, 14), "OPEN", nil)
    cache(pr(APP, 15), "MERGED", "not_live")
    cache(pr(BARE, 1), "MERGED", nil)
    summary(APP, "Deploy", status: "completed", conclusion: "success", created_at: 2.days.ago.iso8601, html_url: "https://github.com/me/app/actions/runs/1")
    summary(LIB, "Deploy lib", status: "completed", conclusion: "failure", created_at: 1.hour.ago.iso8601, html_url: "https://github.com/me/lib/actions/runs/2")
    summary(BARE, nil, nil)
  end

  teardown do
    ENV["WORK_QUEUE_DIR"] = @old
    FileUtils.rm_rf(@dir)
  end

  def pr(repo, number) = "https://github.com/#{repo}/pull/#{number}"

  def done(n, title, pr, now, **extra)
    { n: n, title: title, status: "done", pr: pr, questions: [], log: [], createdAt: now, updatedAt: now }.merge(extra)
  end

  def write(slug, items) = File.write(File.join(@dir, "#{slug}.json"), { items: items }.to_json)

  def cache(url, state, delivery)
    @redis.set(WorkQueue::StatusCache.pr_key(url), { url: url, state: state, merge_sha: "m", merged_at: 3.hours.ago.iso8601 }.to_json)
    body = delivery ? { state: delivery, detail: "x" } : {}
    @redis.set(WorkQueue::StatusCache.delivery_key(url), body.to_json)
  end

  def summary(repo, workflow, run)
    @redis.set(WorkQueue::Delivery.summary_key(repo), { workflow: workflow, run: run, at: Time.current.iso8601 }.to_json)
  end

  # Fake gh for Delivery: one active Deploy workflow; records every `workflow run`.
  def delivery(ok: true)
    @calls = []
    runner = lambda do |*args|
      if args.first == "api"
        [{ workflows: [{ id: 9, name: "Deploy", state: "active" }] }.to_json, true]
      else
        @calls << args
        ["", ok]
      end
    end
    WorkQueue::Delivery.new(runner: runner)
  end

  test "groups merged-not-live tasks by the repo their PR lives in, across projects" do
    releases = WorkQueue::Releases.new
    app = releases.repo(APP)
    assert_equal %w[home-me-app:1 home-me-app:2 home-me-other:1], app.entries.map { |e| e.item.key }.sort
    assert_equal 2, app.prs.size
    assert_equal "ready", app.state
    assert_equal 1, app.entries.find { |e| e.item.n == 2 && e.item.slug == "home-me-app" }.bundle_root
    assert_equal ["home-me-app:4"], releases.repo(LIB).entries.map { |e| e.item.key }, "a follow-up in another repo lands under that repo"
    assert_equal 4, releases.pending_count
  end

  test "live, open, closed-unmerged and unknown tasks are not counted as waiting" do
    releases = WorkQueue::Releases.new
    keys = releases.repos.flat_map { |r| r.entries.map { |e| e.item.key } }
    assert_not_includes keys, "home-me-app:3"
    assert_not_includes keys, "home-me-app:7"
    assert_equal [5], releases.closed_unmerged.map(&:n)
    assert_equal [6], releases.unknown.map(&:n)
  end

  test "a task merged into a branch off main is listed apart, never as deployable" do
    releases = WorkQueue::Releases.new
    assert_equal [[APP, [8]]], releases.stacked.map { |g| [g.name, g.entries.map { |e| e.item.n }] }
    assert_not_includes releases.repo(APP).entries.map { |e| e.item.n }, 8
    flow = WorkQueue::Flow.new(WorkQueue::Store.new.find("home-me-app:8"), Struct.new(:delivery).new(WorkQueue::StatusCache.delivery(pr(APP, 16))))
    assert_equal "Merged into a branch, not on main", flow.label
    assert_includes flow.tags, "unreleased"
    get work_queue_releases_path
    assert_select "#wq_rel_stacked_h", text: /a deploy would not ship these/
  end

  # Fake gh for the stacked cases: `pr list --head feat` answers with `parents`.
  def stack_delivery(parents:, deployed: [])
    runner = lambda do |*args|
      next [parents.to_json, true] if args.first == "pr"

      body = case args[1]
      when %r{/workflows/\d+/runs} then { workflow_runs: deployed.map { |sha| { head_sha: sha, status: "completed", conclusion: "success" } } }
      when %r{/actions/workflows\z} then { workflows: [{ id: 9, name: "Deploy", state: "active" }] }
      when %r{/actions/runs} then { workflow_runs: [] }
      else { status: "behind" }
      end
      [body.to_json, true]
    end
    WorkQueue::Delivery.new(runner: runner)
  end

  def stacked_pr = WorkQueue::PullRequests::Status.new(url: pr(APP, 20), state: "MERGED", base: "feat", head_sha: "h", merge_sha: "m")

  test "a PR merged into a branch follows the PR that carries that branch to main" do
    open_parent = [{ number: 30, state: "OPEN", baseRefName: "main", headRefName: "feat", url: pr(APP, 30) }]
    waiting = stack_delivery(parents: open_parent).compute(stacked_pr)
    assert_equal "stacked", waiting.state
    assert_match(/waiting for PR #30/, waiting.detail)

    merged_parent = [{ number: 30, state: "MERGED", baseRefName: "main", headRefName: "feat", url: pr(APP, 30), mergeCommit: { oid: "pm" } }]
    assert_equal "not_live", stack_delivery(parents: merged_parent).compute(stacked_pr).state
    live = stack_delivery(parents: merged_parent, deployed: ["pm"]).compute(stacked_pr)
    assert_equal "live", live.state
    assert_match(/inside PR #30/, live.detail)

    orphan = stack_delivery(parents: []).compute(stacked_pr)
    assert_equal "stacked", orphan.state
    assert_match(/no pull request to main yet/, orphan.detail)
  end

  test "a repo without a Deploy workflow is listed apart and cannot be deployed" do
    releases = WorkQueue::Releases.new
    assert_equal [BARE], releases.no_workflow.map(&:name)
    assert_nil releases.repo(BARE)
    ok, message = releases.deploy(BARE, delivery: delivery)
    assert_not ok
    assert_match(/nothing merged and waiting/, message)
    assert_empty @calls
  end

  test "one project's view keeps only that project's tasks" do
    releases = WorkQueue::Releases.new(slug: "home-me-other")
    assert_equal ["home-me-other:1"], releases.repo(APP).entries.map { |e| e.item.key }
    assert_nil releases.repo(LIB)
  end

  test "a deployment that never reported a result shows as unknown, not as a failed deploy" do
    hand = "me/hand"
    write("home-me-hand", [done(1, "Deployed by hand", pr(hand, 2), (Time.current.to_f * 1000).to_i)])
    @redis.set(WorkQueue::StatusCache.pr_key(pr(hand, 2)), { url: pr(hand, 2), state: "MERGED", merge_sha: "m" }.to_json)
    @redis.set(WorkQueue::StatusCache.delivery_key(pr(hand, 2)), { state: "not_live", detail: "never reported a result", unknown: true }.to_json)
    run = { status: "completed", conclusion: WorkQueue::Delivery::NO_RESULT, created_at: 2.hours.ago.iso8601 }
    @redis.set(WorkQueue::Delivery.summary_key(hand), { workflow: nil, run: run, source: "deployments", at: Time.current.iso8601 }.to_json)

    repo = WorkQueue::Releases.new.repo(hand)
    assert_equal ["ready", "unknown"], [repo.state, repo.summary.run_state]
    flow = WorkQueue::Flow.new(WorkQueue::Store.new.find("home-me-hand:1"), Struct.new(:delivery).new(repo.entries.first.delivery))
    assert_equal "Deploy result unknown", flow.label

    get work_queue_releases_path
    assert_select "#wq_rel_me-hand .wq-pill", text: "Deploy result unknown"
    assert_select "#wq_rel_me-hand .wq-pill-bad", count: 0
    assert_select "#wq_rel_me-hand .wq-rel-head .wq-hint", text: /result unknown, started about 2 hours ago/
    assert_select "#wq_rel_me-hand .wq-rel-head .wq-hint", text: /failed/, count: 0
  end

  test "a failed deploy run marks the repo failed and still deployable (retry)" do
    lib = WorkQueue::Releases.new.repo(LIB)
    assert_equal "failed", lib.state
    assert lib.deployable?
    assert_equal "failed", lib.summary.run_state
  end

  test "deploy dispatches the workflow once for the repo and notes every task" do
    ok, message = WorkQueue::Releases.new.deploy(APP, delivery: delivery)
    assert ok, message
    assert_equal [["workflow", "run", "9", "--ref", "main", "-R", APP]], @calls
    store = WorkQueue::Store.new
    %w[home-me-app:1 home-me-app:2 home-me-other:1].each do |key|
      assert_match(/Release: Started Deploy on main \(3 merged tasks from myjira\)/, store.find(key).log.last["text"], key)
    end
    assert_no_match(/Release:/, store.find("home-me-app:3").log.to_json)

    again = WorkQueue::Releases.new
    assert_equal "deploying", again.repo(APP).state, "shows Deploying until GitHub lists the new run"
    assert_not again.repo(APP).deployable?
    assert_equal [false, "#{APP} is already deploying"], again.deploy(APP, delivery: delivery)
    assert_empty @calls
  end

  test "a failed dispatch writes no notes and leaves the repo ready" do
    ok, message = WorkQueue::Releases.new.deploy(APP, delivery: delivery(ok: false))
    assert_not ok
    assert_match(/gh workflow run failed/, message)
    assert_empty WorkQueue::Store.new.find("home-me-app:1").log
    assert_equal "ready", WorkQueue::Releases.new.repo(APP).state
  end

  test "others_for lists what else a single task's deploy would ship" do
    item = WorkQueue::Store.new.find("home-me-app:1")
    assert_equal %w[home-me-app:2 home-me-other:1], WorkQueue::Releases.new.others_for(item).map { |e| e.item.key }.sort
  end

  test "computing a merged PR's delivery records the repo summary; an outage records nothing" do
    status = WorkQueue::PullRequests::Status.new(url: pr("me/new", 1), state: "MERGED", head_sha: "h", merge_sha: "m")
    runner = lambda do |_api, path|
      body = case path
      when %r{/workflows/\d+/runs} then { workflow_runs: [{ status: "in_progress", conclusion: nil, created_at: "2026-11-24T10:00:00Z", html_url: "https://x/run", head_sha: "zzz" }] }
      when %r{/actions/workflows\z} then { workflows: [{ id: 9, name: "Deploy", state: "active" }] }
      when %r{/actions/runs} then { workflow_runs: [] }
      else { status: "behind" }
      end
      [body.to_json, true]
    end
    assert_equal "not_live", WorkQueue::Delivery.new(runner: runner).compute(status).state
    summary = WorkQueue::Delivery.summary("me/new")
    assert_equal "Deploy", summary.workflow
    assert_equal "running", summary.run_state

    down = WorkQueue::PullRequests::Status.new(url: pr("me/down", 1), state: "MERGED", head_sha: "h", merge_sha: "m")
    assert_raises(WorkQueue::Delivery::Unavailable) { WorkQueue::Delivery.new(runner: ->(*) { ["", false] }).compute(down) }
    assert_nil WorkQueue::Delivery.summary("me/down")
  end

  test "the releases page lists each repo with its tasks, last run and one confirm panel" do
    get work_queue_releases_path
    assert_response :ok
    assert_select "#wq_rel_me-app .wq-rel-name", text: APP
    assert_select "#wq_rel_me-app .wq-rel-table tbody tr", 3
    assert_select "#wq_rel_me-app a[href='https://github.com/me/app/actions/runs/1']", text: /succeeded/
    assert_select "#wq_rel_me-app .wq-rel-table", text: /bundle of task 1/
    assert_select "#wq_rel_me-app details.wq-rel-confirm", 1
    assert_select "#wq_rel_me-app .wq-rel-panel input[name=repo][value='#{APP}']"
    assert_select "#wq_rel_me-app .wq-rel-out li", 3
    assert_select "#wq_rel_me-app .wq-rel-panel", text: /This goes out \(3 tasks\)/
    assert_select "#wq_rel_me-app .wq-rel-warn", text: /deploys main to production and cannot be undone from here/
    assert_select "#wq_rel_me-lib .wq-pill-bad", text: "Deploy failed"
    assert_select "#wq_rel_me-lib details.wq-rel-confirm summary", text: /Retry deploy of lib/
    assert_select "#wq_rel_me-lib a[href='https://github.com/me/lib/actions/runs/2']"
    assert_select "#wq_rel_loose_h", text: /No Deploy workflow: nothing to release from here/
    assert_select ".wq-rel-loose summary", text: /me\/bare/
    assert_select ".wq-rel-tiles dd", text: "4"
  end

  test "posting a deploy runs it once and shows the repo as deploying" do
    fake = delivery
    WorkQueue::Delivery.stub(:new, fake) do
      post work_queue_releases_deploy_path, params: { repo: APP }
    end
    assert_redirected_to work_queue_releases_path
    assert_equal 1, @calls.size
    follow_redirect!
    assert_select "#wq_rel_me-app .wq-pill-run", text: /Deploying/
    assert_select "#wq_rel_me-app details.wq-rel-confirm", 0
    assert_select "turbo-frame#wq_releases[src]"
  end

  test "a bad repo name never reaches gh" do
    fake = delivery
    WorkQueue::Delivery.stub(:new, fake) do
      post work_queue_releases_deploy_path, params: { repo: "../etc; rm" }
    end
    assert_redirected_to work_queue_releases_path
    assert_empty @calls
  end

  test "a task's own Deploy panel says how many other merged tasks go out with it" do
    get work_queue_item_detail_path("home-me-app:1")
    assert_response :ok
    assert_select ".wq-merge-panel a[href='#{work_queue_releases_path}']", text: /2 other merged tasks would go out with this deploy/
  end

  test "the Releases page says what the cleanup after deploy left, and why" do
    state = { at: 5.minutes.ago.iso8601, removed: [{ kind: "remote", target: "wq/3-live" }],
              skipped: [{ kind: "worktree", target: "/home/me/app-wq-3", reason: "files owned by another user; remove with sudo", detail: "log/test.log" }] }
    @redis.hset(WorkQueue::WorktreeCleaner.mark_key("home-me-app:3"), "state", state.to_json)
    @redis.hset(WorkQueue::CleanupReport::ORPHANS_KEY, "/home/me/app", {
      name: APP, slugs: ["home-me-app"], at: 1.hour.ago.iso8601, dry_run: true,
      removed: [{ kind: "local", target: "worktree-agent-a1", detail: "was abc1234" }],
      skipped: [{ kind: "worktree", target: "/home/me/app/.claude/worktrees/agent-b2", reason: "it is locked by an agent that is still running", detail: "pid 42" }]
    }.to_json)

    get work_queue_releases_path
    assert_response :success
    assert_select "#wq_rel_cleanup_h"
    assert_select "section[aria-labelledby=wq_rel_cleanup_h] > table tbody tr", 1 do
      assert_select "a", text: /#3 Already live/
      assert_select "td", text: /files owned by another user; remove with sudo/
      assert_select ".wq-pill-bad", text: "worktree"
    end
    assert_select "details.wq-rel-loose summary", text: /would remove 1, left 1/
    assert_select "details.wq-rel-loose td", text: /it is locked by an agent that is still running/
    assert_select "details.wq-rel-loose .wq-pill-wait", text: "Would remove"

    get work_queue_releases_path(slug: "home-me-other")
    assert_select "#wq_rel_cleanup_h", 0
  end

  test "the task detail shows the cleanup state and the reason something was left" do
    get work_queue_item_detail_path("home-me-app:1")
    assert_select ".wq-cleanup .wq-pill-wait", text: "Cleanup waiting"
    assert_select ".wq-cleanup", text: /merged but not deployed yet \(not live\)/

    state = { at: 5.minutes.ago.iso8601, removed: [], skipped: [{ kind: "local", target: "wq/3-live", reason: "it is still checked out in a worktree" }] }
    @redis.hset(WorkQueue::WorktreeCleaner.mark_key("home-me-app:3"), "state", state.to_json)
    get work_queue_item_detail_path("home-me-app:3")
    assert_select ".wq-cleanup .wq-pill-bad", text: "Cleanup left 1 thing"
    assert_select ".wq-cleanup li", text: /Left local branch\s+wq\/3-live: it is still checked out in a worktree/

    get work_queue_item_detail_path("home-me-app:7")
    assert_select ".wq-cleanup", 0
  end
end
