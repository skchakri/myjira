require "test_helper"

class WorkQueueCostsTest < ActiveSupport::TestCase
  Item = Struct.new(:n)

  setup do
    redis = WorkQueue::RunState.redis
    redis.scan_each(match: "#{WorkQueue::RunState::PREFIX}:*") { |k| redis.del(k) }
  end

  def record(key, phase, model, cost)
    WorkQueue::RunState.record_phase(key, { phase: phase, model: model, effort: "high", cost_usd: cost })
  end

  test "a recorded phase adds to the item, the day and the phase-model mix" do
    record("home-me-a:1", "plan", "claude-opus-5-5", 1.5)
    record("home-me-a:1", "implement", "claude-sonnet-5-5", 0.25)
    record("home-me-a:2", "plan", "claude-opus-5-5", 0.5)
    record("home-me-a:3", "plan", "claude-opus-5-5", nil) # a failed phase with no cost

    costs = WorkQueue::Costs.project("home-me-a")
    assert_in_delta 1.75, costs.item(1)
    assert_in_delta 0.5, costs.item(2)
    assert_in_delta 0.0, costs.item(3)
    assert_in_delta 2.25, costs.total
    assert_in_delta 2.25, WorkQueue::Costs.today("home-me-a")
  end

  test "a tree total is the item plus everything below it, each counted once" do
    record("home-me-a:1", "plan", "m", 1.0)
    record("home-me-a:2", "plan", "m", 0.5)
    record("home-me-a:4", "plan", "m", 0.25)
    costs = WorkQueue::Costs.project("home-me-a")
    assert_in_delta 1.75, costs.tree(Item.new(1), [Item.new(2), Item.new(4), Item.new(2), Item.new(9)])
    assert_in_delta 0.5, costs.tree(Item.new(2))
  end

  test "overview totals projects, days, the mix and the top tasks" do
    record("home-me-a:1", "plan", "claude-opus-5-5", 2.0)
    record("home-me-b:7", "plan", "claude-opus-5-5", 1.0)
    record("home-me-b:8", "implement", "claude-sonnet-5-5", 0.5)
    WorkQueue::Costs.add("home-me-b:8", 4.0, phase: "plan", model: "claude-opus-5-5", day: Time.zone.today - 3)
    WorkQueue::Costs.add("home-me-b:8", 9.0, phase: "plan", model: "claude-opus-5-5", day: Time.zone.today - 40)

    o = WorkQueue::Costs.overview
    assert_in_delta 16.5, o.total
    assert_equal %w[home-me-b home-me-a], o.projects.pluck(:slug)
    b = o.projects.first
    assert_in_delta 1.5, b[:today]
    assert_in_delta 5.5, b[:recent], 0.001, "the 40-day-old cost is outside the window"
    assert_equal 2, b[:tasks]
    assert_equal WorkQueue::Costs::DAYS, o.days.size
    assert_in_delta 3.5, o.days.last.last
    assert_in_delta 4.0, o.days[-4].last
    assert_equal({ phase: "plan", model: "claude-opus-5-5" }, o.mix.first.slice(:phase, :model))
    assert_in_delta 16.0, o.mix.first[:cost]
    assert_equal [["home-me-b", 8], ["home-me-a", 1], ["home-me-b", 7]], o.top.map { |r| [r[:slug], r[:n]] }
  end

  test "overview is empty with nothing recorded" do
    o = WorkQueue::Costs.overview
    assert_in_delta 0.0, o.total
    assert_empty o.projects
    assert_equal WorkQueue::Costs::DAYS, o.days.size
  end

  test "rebuild recounts the totals from the phase records" do
    record("home-me-a:1", "plan", "claude-opus-5-5", 1.5)
    record("home-me-a:2", "implement", "claude-sonnet-5-5", 0.5)
    WorkQueue::Costs.add("home-me-a:1", 99, phase: "plan", model: "x") # drift that a rebuild removes
    assert_equal 2, WorkQueue::Costs.rebuild!
    assert_in_delta 2.0, WorkQueue::Costs.overview.total
    assert_in_delta 1.5, WorkQueue::Costs.project("home-me-a").item(1)
  end
end
