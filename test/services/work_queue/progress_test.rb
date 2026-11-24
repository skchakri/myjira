require "test_helper"

class WorkQueueProgressTest < ActiveSupport::TestCase
  FakeContext = Struct.new(:run, :pr_status, :delivery)

  def item(n, status, **attrs)
    WorkQueue::Store::Item.new(slug: "app", n: n, title: "T#{n}", status: status, questions: [], log: [], **attrs)
  end

  def flow(i, run: {}, delivery: nil) = WorkQueue::Flow.new(i, FakeContext.new(run, nil, delivery))

  test "own percent follows the phase, with half a phase while running" do
    assert_equal 0, flow(item(1, "queued")).percent
    assert_equal 0, flow(item(1, "triage")).percent
    assert_equal 8, flow(item(1, "running"), run: { "phase" => "plan" }).percent
    assert_equal 25, flow(item(1, "running"), run: { "phase" => "implement" }).percent
    assert_equal 25, flow(item(1, "running")).percent
    assert_equal 42, flow(item(1, "running"), run: { "phase" => "review" }).percent
    assert_equal 17, flow(item(1, "blocked")).percent
    assert_equal 50, flow(item(1, "review")).percent
    assert_equal 67, flow(item(1, "review", pr: "12")).percent
    not_live = WorkQueue::Delivery::State.new(state: "not_live", detail: "x")
    assert_equal 83, flow(item(1, "done", pr: "12"), delivery: not_live).percent
    assert_equal 100, flow(item(1, "done")).percent
    assert_predicate flow(item(1, "done")), :finished?
  end

  test "dropped and folded items have no percent" do
    assert_nil flow(item(1, "dropped")).percent
    assert_nil flow(item(1, "merged", merged_into: 2)).percent
  end

  test "a parent rolls up itself and every level below it" do
    items = [item(1, "done"), item(2, "done", parent: 1), item(3, "queued", parent: 1),
             item(4, "review", parent: 3), item(5, "queued")]
    roll = WorkQueue::Progress.new(items).for(items[0])
    assert_equal 100, roll.own
    assert_equal 63, roll.percent # (100 + 100 + 0 + 50) / 4
    assert_equal [3, 1, 2], [roll.total, roll.done, roll.left]
    assert roll.active
    assert_predicate roll, :parent?
    assert_equal [4], roll.need_you.map(&:n) # review without a PR waits on the person

    leaf = WorkQueue::Progress.new(items).for(items[4])
    assert_equal [0, 0, 0, false], [leaf.percent, leaf.total, leaf.done, leaf.active]
    assert_not leaf.parent?
  end

  test "dropped and folded children are left out of the rollup" do
    items = [item(1, "review"), item(2, "dropped", parent: 1), item(3, "merged", parent: 1, merged_into: 1), item(4, "done", parent: 1)]
    roll = WorkQueue::Progress.new(items).for(items[0])
    assert_equal 75, roll.percent # (50 + 100) / 2
    assert_equal [1, 1], [roll.total, roll.done]
    assert_not roll.active
    assert_nil WorkQueue::Progress.new(items).for(items[1]).percent
  end

  test "a parent cycle is walked once" do
    items = [item(1, "queued", parent: 2), item(2, "done", parent: 1)]
    progress = WorkQueue::Progress.new(items)
    assert_equal [2], progress.descendants(items[0]).map(&:n)
    assert_equal 50, progress.for(items[0]).percent
    assert_equal 50, progress.for(items[1]).percent
  end

  test "given flows win over the ones it would build" do
    i = item(1, "running")
    progress = WorkQueue::Progress.new([i], flows: { i.key => flow(i, run: { "phase" => "review" }) })
    assert_equal 42, progress.for(i).percent
  end

  test "happening skips routing and status lines and falls back to the phase" do
    log = [{ "text" => "Suggested as follow-up of #3" }, { "text" => "→ running" }, { "text" => "plan: claude-opus-5-5 / high (escalation)" }]
    assert_equal "Planning now.", flow(item(1, "running", log: log), run: { "phase" => "plan" }).happening
    assert_equal "Building now.", flow(item(1, "running")).happening
    assert_equal "Suggested as follow-up of #3", flow(item(1, "blocked", log: log)).happening
    assert_equal "Did it", flow(item(1, "running", log: log, summary: "Did it")).happening
    assert_equal "Nothing recorded yet.", flow(item(1, "queued", log: [{ "text" => "→ queued" }])).happening
  end
end
