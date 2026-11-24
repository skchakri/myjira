require "test_helper"

class WorkQueueFlowTest < ActiveSupport::TestCase
  FakeContext = Struct.new(:run, :pr_status, :delivery)

  def item(**attrs)
    WorkQueue::Store::Item.new(slug: "app", n: 1, title: "T", status: "queued", questions: [], log: [], **attrs)
  end

  test "running phase picks building, planning or testing" do
    assert_equal ["Building", 2, "run"], flow(item(status: "running"), run: {}).then { |f| [f.label, f.step, f.tone] }
    assert_equal "Planning", flow(item(status: "running"), run: { "phase" => "plan" }).label
    f = flow(item(status: "running"), run: { "phase" => "review" })
    assert_equal ["Testing", 4], [f.label, f.step]
    assert_includes f.tags, "testing"
  end

  test "review with a conflicting PR is failed, otherwise ready to merge" do
    pr = WorkQueue::PullRequests::Status.new(state: "OPEN", mergeable: "CONFLICTING")
    assert_equal "bad", flow(item(status: "review", pr: "12"), pr_status: pr).tone
    assert_includes flow(item(status: "review", pr: "12")).tags, "merge"
    assert_equal "Ready for review", flow(item(status: "review")).label
  end

  test "path marks done steps and the current one" do
    f = flow(item(status: "blocked"))
    assert_equal ["done", "done", "now-bad", nil, nil, nil], f.path
    assert_equal ["done"] * 6, flow(item(status: "done")).path
    assert_equal "task 1 · PR #7 · branch b", flow(item(pr: "https://x/pull/7", branch: "b")).ref
  end

  test "red checks on an open PR mark it failed and list the checks" do
    pr = WorkQueue::PullRequests::Status.new(state: "OPEN", mergeable: "MERGEABLE", failed_checks: %w[test lint])
    f = flow(item(status: "review", pr: "12"), pr_status: pr)
    assert_equal ["bad", "Failed checks"], [f.tone, f.label]
    assert_includes f.tags, "bad"
    assert_equal %w[test lint], f.failed_checks
  end

  test "done items follow the delivery state" do
    d = ->(state, failed = nil) { WorkQueue::Delivery::State.new(state: state, detail: "x", failed: failed) }
    done = item(status: "done", pr: "12")
    assert_equal "Live", flow(done).label
    assert_equal ["Testing together", 4], flow(done, delivery: d.call("testing")).then { |f| [f.label, f.step] }
    assert_includes flow(done, delivery: d.call("deploying")).tags, "testing"
    nl = flow(done, delivery: d.call("not_live"))
    assert_equal "Merged, not live yet", nl.label
    assert_includes nl.tags, "open"
    assert_equal "Live", flow(done, delivery: d.call("live")).label
    assert_equal ["Deploy"], flow(done, delivery: d.call("deploy_failed", ["Deploy"])).failed_checks
    assert_equal "Testing together", flow(item(status: "review", pr: "12"), delivery: d.call("testing")).label
  end

  test "a running item with no activity for 30 minutes is stalled" do
    f = WorkQueue::Flow.new(item(status: "running", updated_at: 11.hours.ago))
    assert f.stalled?
    assert_equal ["bad", "Stalled: no activity for 11h"], [f.tone, f.label]
    assert_equal %w[all open bad you stalled], f.tags
    assert_equal "Resume it, or tell the agent what to do.", f.your_part
    assert_equal 25, f.percent
    assert_match(/\ANo activity since /, f.happening)

    assert_equal "Stalled: no activity for 45m", WorkQueue::Flow.new(item(status: "running", updated_at: 45.minutes.ago)).label
    assert_equal "Stalled: no activity for 5d", WorkQueue::Flow.new(item(status: "running", updated_at: 5.days.ago)).label
    assert_not WorkQueue::Flow.new(item(status: "running", updated_at: 10.minutes.ago)).stalled?
    assert_not WorkQueue::Flow.new(item(status: "running")).stalled?
    assert_not WorkQueue::Flow.new(item(status: "review", updated_at: 3.days.ago)).stalled?
  end

  test "recent transcript writes or a live runner process keep an old item from stalling" do
    Activity = Struct.new(:run, :last_activity, :live_pid?) unless self.class.const_defined?(:Activity)
    old = item(status: "running", updated_at: 6.hours.ago)
    assert_not WorkQueue::Flow.new(old, Activity.new({}, 2.minutes.ago, false)).stalled?
    assert_not WorkQueue::Flow.new(old, Activity.new({ "phase" => "plan" }, 6.hours.ago, true)).stalled?
    f = WorkQueue::Flow.new(old, Activity.new({ "phase" => "plan" }, 6.hours.ago, false))
    assert_equal ["Stalled: no activity for 6h", 1], [f.label, f.step]
  end

  test "item context takes the latest of queue time, last log line and transcript mtime" do
    Dir.mktmpdir do |root|
      dir = File.join(root, "proj")
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "sess-1.jsonl")
      File.write(path, "")
      File.utime(5.minutes.ago.to_time, 5.minutes.ago.to_time, path)
      old = ENV["CLAUDE_PROJECTS_DIR"]
      ENV["CLAUDE_PROJECTS_DIR"] = root
      i = item(status: "running", updated_at: 6.hours.ago, session: "sess-1", log: [{ "at" => (2.hours.ago.to_f * 1000).to_i, "text" => "x" }])
      ctx = WorkQueue::ItemContext.new(i, store: WorkQueue::Store.new(dir: root))
      assert_in_delta 5.minutes.ago.to_f, ctx.last_activity.to_f, 5
      assert_not ctx.flow.stalled?
      File.delete(path)
      ctx = WorkQueue::ItemContext.new(i, store: WorkQueue::Store.new(dir: root))
      assert_in_delta 2.hours.ago.to_f, ctx.last_activity.to_f, 5
      assert ctx.flow.stalled?
    ensure
      ENV["CLAUDE_PROJECTS_DIR"] = old
    end
  end

  private

  def flow(i, run: {}, pr_status: nil, delivery: nil) = WorkQueue::Flow.new(i, FakeContext.new(run, pr_status, delivery))
end
