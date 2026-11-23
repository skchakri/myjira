require "test_helper"

class WorkQueueDeliveryTest < ActiveSupport::TestCase
  URL = "https://github.com/me/app/pull/5".freeze
  DEPLOY = { id: 9, name: "Deploy", state: "active" }.freeze

  def pr(**attrs)
    WorkQueue::PullRequests::Status.new(url: URL, state: "MERGED", head_sha: "h1", merge_sha: "m1", **attrs)
  end

  # Fake gh: runs/workflows/deploy runs as given; compare says head contains base when listed.
  def delivery(runs: [], workflows: [], deploy_runs: [], contains: [])
    runner = lambda do |_api, path|
      body = case path
      when %r{/workflows/\d+/runs} then { workflow_runs: deploy_runs }
      when %r{/actions/workflows\z} then { workflows: workflows }
      when %r{/actions/runs} then { workflow_runs: runs }
      when %r{/compare/(\w+)\.\.\.(\w+)} then { status: contains.include?([$1, $2]) ? "ahead" : "behind" }
      end
      [body.to_json, true]
    end
    WorkQueue::Delivery.new(runner: runner)
  end

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

  test "deploy states from main-branch deploy runs containing the merge commit" do
    ok = { head_sha: "d1", status: "completed", conclusion: "success" }
    running = { head_sha: "d1", status: "in_progress" }
    bad = { head_sha: "d1", status: "completed", conclusion: "failure" }
    c = [%w[m1 d1]]
    assert_equal "live", delivery(workflows: [DEPLOY], deploy_runs: [ok], contains: c).compute(pr).state
    assert_equal "deploying", delivery(workflows: [DEPLOY], deploy_runs: [running], contains: c).compute(pr).state
    assert_equal "deploy_failed", delivery(workflows: [DEPLOY], deploy_runs: [bad], contains: c).compute(pr).state
    assert_equal "not_live", delivery(workflows: [DEPLOY], deploy_runs: [ok], contains: []).compute(pr).state
  end
end
