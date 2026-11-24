require "test_helper"

class WorkQueueDeliveryTest < ActiveSupport::TestCase
  URL = "https://github.com/me/app/pull/5".freeze
  DEPLOY = { id: 9, name: "Deploy", state: "active" }.freeze
  LIMITED = "gh: API rate limit exceeded for user ID 1. (HTTP 403)".freeze

  setup do
    @redis = WorkQueue::RunState.redis
    @redis.scan_each(match: "#{WorkQueue::RunState::PREFIX}:*") { |k| @redis.del(k) }
    @calls = []
  end

  def pr(**attrs)
    WorkQueue::PullRequests::Status.new(url: URL, state: "MERGED", head_sha: "h1", merge_sha: "m1", **attrs)
  end

  # The heads the fake gh was asked to compare against, in order.
  def compared = @calls.grep(%r{/compare/}).map { |path| path[/\w+\z/] }

  # Fake gh: runs/workflows/deploy runs as given; compare says head contains base when listed.
  # `down` makes the REST reads matching `down_on` fail with that stderr. Every `gh api` path
  # lands in @calls, except the free rate_limit lookup, which answers a reset `reset_in` away.
  def delivery(runs: [], workflows: [], deploy_runs: [], contains: [], down: nil, down_on: //, reset_in: 600)
    runner = lambda do |*args|
      path = args[1]
      next [(Time.current.to_i + reset_in).to_s, true, ""] if path == "rate_limit"

      @calls << path
      next ["", false, down] if down && path.match?(down_on)

      body = case path
      when %r{/workflows/\d+/runs} then { workflow_runs: deploy_runs }
      when %r{/actions/workflows\z} then { workflows: workflows }
      when %r{/actions/runs} then { workflow_runs: runs }
      when %r{/compare/(\w+)\.\.\.(\w+)} then { status: contains.include?([$1, $2]) ? "ahead" : "behind" }
      end
      [body.to_json, true, ""]
    end
    WorkQueue::Delivery.new(runner: runner)
  end

  def deploy_run(sha, status: "completed", conclusion: "success") = { head_sha: sha, status: status, conclusion: conclusion }
  def running(sha) = deploy_run(sha, status: "in_progress", conclusion: nil)
  def red(sha) = deploy_run(sha, conclusion: "failure")

  test "pr view parses failed checks from the rollup" do
    json = { url: URL, state: "OPEN", statusCheckRollup: [
      { name: "test", status: "COMPLETED", conclusion: "FAILURE" },
      { name: "lint", status: "COMPLETED", conclusion: "SUCCESS" },
      { context: "ci/x", state: "ERROR" },
      { name: "slow", status: "COMPLETED", conclusion: "TIMED_OUT" }
    ] }
    st = WorkQueue::PullRequests.new(runner: ->(*) { [json.to_json, true] }).fetch("5")
    assert_equal %w[test ci/x slow], st.failed_checks
    assert_equal "me/app", st.repo
  end

  test "no deploy workflow and no batch: nothing to say (stays Live)" do
    assert_nil delivery.compute(pr)
  end

  test "batch CI running on a batch containing the PR is testing together" do
    runs = [{ head_branch: "batch/1", head_sha: "b1", status: "in_progress", name: "CI" }]
    assert_equal "testing", delivery(runs: runs, contains: [%w[h1 b1]]).compute(pr(state: "OPEN")).state
  end

  test "red batch on an open PR is ci_failed" do
    runs = [{ head_branch: "batch/1", head_sha: "b1", status: "completed", conclusion: "failure", name: "CI" }]
    s = delivery(runs: runs, contains: [%w[h1 b1]]).compute(pr(state: "OPEN"))
    assert_equal ["ci_failed", ["CI"]], [s.state, s.failed]
  end

  test "a merged PR is only compared against batches still running" do
    runs = [
      { head_branch: "batch/3", head_sha: "b3", status: "completed", conclusion: "success", name: "CI" },
      { head_branch: "batch/2", head_sha: "b2", status: "in_progress", name: "CI" },
      { head_branch: "batch/1", head_sha: "b1", status: "completed", conclusion: "failure", name: "CI" }
    ]
    assert_equal "testing", delivery(runs: runs, contains: [%w[h1 b2]]).compute(pr).state
    assert_equal ["b2"], compared
  end

  test "deploy states from main-branch deploy runs containing the merge commit" do
    wf = { workflows: [DEPLOY] }
    assert_equal "live", delivery(**wf, deploy_runs: [deploy_run("d1")], contains: [%w[m1 d1]]).compute(pr).state
    assert_equal "deploying", delivery(**wf, deploy_runs: [running("d2")], contains: [%w[m1 d2]]).compute(pr).state
    assert_equal "deploy_failed", delivery(**wf, deploy_runs: [red("d3")], contains: [%w[m1 d3]]).compute(pr).state
    assert_equal "not_live", delivery(**wf, deploy_runs: [deploy_run("d4")], contains: []).compute(pr).state
  end

  test "live takes one compare, against the newest green deploy, however many runs there are" do
    runs = [red("d9"), deploy_run("d8"), *7.downto(1).map { |i| deploy_run("d#{i}") }]
    d = delivery(workflows: [DEPLOY], deploy_runs: runs, contains: [%w[m1 d8]])
    assert_equal "live", d.compute(pr).state
    assert_equal ["d8"], compared
  end

  test "deploying and failed look only at running runs and the newest finished one after the last green" do
    old = 6.downto(1).map { |i| deploy_run("d#{i}") }
    going = [running("d9"), red("d8"), *old]
    assert_equal "deploying", delivery(workflows: [DEPLOY], deploy_runs: going, contains: [%w[m1 d9]]).compute(pr).state
    assert_equal %w[d6 d9], compared

    @calls.clear
    failed = [red("e9"), red("e8"), *old]
    assert_equal "deploy_failed", delivery(workflows: [DEPLOY], deploy_runs: failed, contains: [%w[m1 e9]]).compute(pr).state
    assert_equal ["e9"], compared # d6 is already known from Redis

    @calls.clear
    assert_equal "not_live", delivery(workflows: [DEPLOY], deploy_runs: [red("f9"), *old]).compute(pr).state
    assert_equal ["f9"], compared
  end

  test "a compare answer is kept in Redis: a new process asks nothing" do
    args = { workflows: [DEPLOY], deploy_runs: [deploy_run("d1")] }
    assert_equal "live", delivery(**args, contains: [%w[m1 d1]]).compute(pr).state
    assert_equal ["d1"], compared
    assert_equal "1", @redis.get(WorkQueue::Delivery.contains_key("me/app", "m1", "d1"))
    assert_operator @redis.ttl(WorkQueue::Delivery.contains_key("me/app", "m1", "d1")), :>, 29.days.to_i

    assert_equal "live", delivery(**args, contains: []).compute(pr).state # a fresh Delivery, same Redis
    assert_equal ["d1"], compared
  end

  test "a failed compare is not kept and never becomes a state" do
    args = { workflows: [DEPLOY], deploy_runs: [deploy_run("d1")], contains: [%w[m1 d1]] }
    d = delivery(**args, down: "gh: Server Error (HTTP 502)", down_on: %r{/compare/})
    assert_raises(WorkQueue::Delivery::Unavailable) { d.compute(pr) }
    assert_equal ["d1"], compared
    assert_empty @redis.keys("#{WorkQueue::RunState::PREFIX}:contains:*")
    assert_nil WorkQueue::Delivery.paused_until

    assert_equal "live", delivery(**args).compute(pr).state # asked again, and answered this time
    assert_equal %w[d1 d1], compared
  end

  test "a commit GitHub no longer has reads as not contained, kept only briefly" do
    d = delivery(workflows: [DEPLOY], deploy_runs: [deploy_run("d1")], down: "gh: Not Found (HTTP 404)", down_on: %r{/compare/})
    assert_equal "not_live", d.compute(pr).state
    key = WorkQueue::Delivery.contains_key("me/app", "m1", "d1")
    assert_equal "0", @redis.get(key)
    assert_operator @redis.ttl(key), :<=, WorkQueue::Delivery::MISSING_TTL
  end

  test "a used-up rate limit pauses every REST call until the reset" do
    d = delivery(workflows: [DEPLOY], down: LIMITED, reset_in: 600)
    assert_raises(WorkQueue::Delivery::Unavailable) { d.compute(pr) }
    assert_equal 1, @calls.size
    assert_in_delta 605, WorkQueue::Delivery.paused_until - Time.current, 5
    assert_in_delta 605, @redis.ttl(WorkQueue::Delivery::PAUSE_KEY), 5

    working = delivery(workflows: [DEPLOY], deploy_runs: [deploy_run("d1")], contains: [%w[m1 d1]])
    error = assert_raises(WorkQueue::Delivery::Unavailable) { working.compute(pr) }
    assert_match(/rate limit used up until/, error.message)
    assert_equal [false, "GitHub could not be asked: #{error.message}"], working.deploy_repo("me/app")
    assert_equal 1, @calls.size # nothing was asked while paused

    @redis.del(WorkQueue::Delivery::PAUSE_KEY) # the reset
    assert_equal "live", working.compute(pr).state
  end

  test "status refresh keeps the last delivery state while GitHub cannot be asked" do
    item = Struct.new(:pr, :key) { def open? = false }.new(URL, "p#1")
    prs = Struct.new(:status) { def fetch(_) = status }.new(pr)
    args = { workflows: [DEPLOY], deploy_runs: [deploy_run("d1")], contains: [%w[m1 d1]] }
    WorkQueue::StatusCache.refresh(item, store: nil, prs: prs, delivery: delivery(**args))
    assert_equal "live", WorkQueue::StatusCache.delivery(URL).state
    summary = @redis.get(WorkQueue::Delivery.summary_key("me/app"))
    assert summary

    changed = WorkQueue::StatusCache.refresh(item, store: nil, prs: prs, delivery: delivery(**args, down: LIMITED))
    assert_not changed
    assert_equal "live", WorkQueue::StatusCache.delivery(URL).state
    assert_equal summary, @redis.get(WorkQueue::Delivery.summary_key("me/app"))
  end
end
