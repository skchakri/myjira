require "test_helper"

class WorkQueueFlowTest < ActiveSupport::TestCase
  FakeContext = Struct.new(:run, :pr_status)

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

  private

  def flow(i, run: {}, pr_status: nil) = WorkQueue::Flow.new(i, FakeContext.new(run, pr_status))
end
