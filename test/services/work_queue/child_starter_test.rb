require "test_helper"

class WorkQueueChildStarterTest < ActiveSupport::TestCase
  SLUG = "home-me-app".freeze

  class FakeDispatcher
    class << self
      attr_accessor :listening, :sent
    end

    def initialize(item) = (@item = item)
    def listening? = self.class.listening
    def run_now = (self.class.sent << @item.n)
  end

  setup do
    @dir = Dir.mktmpdir("wq")
    @writer = WorkQueue::QueueWriter.new(dir: @dir)
    @store = WorkQueue::Store.new(dir: @dir)
    @jobs = []
    FakeDispatcher.listening = false
    FakeDispatcher.sent = []
    @writer.add(SLUG, title: "Parent")
    @writer.add(SLUG, title: "Kid", parent: 1)
    @writer.update(SLUG, 2) { |i| i["awaitingApproval"] = true } # as the CLI mod files follow-ups
    @writer.add(SLUG, title: "Root awaiting")
    @writer.update(SLUG, 3) { |i| i["awaitingApproval"] = true }
  end

  teardown { FileUtils.rm_rf(@dir) }

  def starter(limit: nil, waiting: 0)
    WorkQueue::ChildStarter.new(writer: @writer, dispatcher: FakeDispatcher, enqueue: ->(action, key) { @jobs << [action, key] },
                                limit: ->(_slug) { limit }, waiting: ->(_items) { waiting }, since: 1.hour.ago)
  end

  def items = @store.items_for(SLUG)
  def find(n) = @store.find("#{SLUG}:#{n}")

  test "over the limit an agent-filed follow-up is held, then released oldest first once the person catches up" do
    @writer.add(SLUG, title: "Second kid", parent: 1) # as the CLI mod files them now: no approval flag
    changed = starter(limit: 2, waiting: 3).call(items)
    assert_equal [2, 4], changed.map(&:n).sort
    assert find(2).held?
    assert find(4).held?
    assert_not find(2).awaiting_approval
    assert_includes find(4).log.map { |l| l["text"] }, "Held: 3 tasks are waiting on you in this project (limit 2)"
    assert_equal "Held: waiting for you to catch up", WorkQueue::Flow.new(find(4)).label
    assert_includes WorkQueue::Flow.new(find(4)).tags, "wait"
    assert_empty @jobs
    assert_empty starter(limit: 2, waiting: 3).call(items), "held ones stay held while over the limit"

    released = starter(limit: 2, waiting: 1).call(items)
    assert_equal [2, 4], released.map(&:n)
    assert_equal [["start", "#{SLUG}:2"], ["start", "#{SLUG}:4"]], @jobs
    assert_not find(4).held?
    assert_equal true, find(4).follow_up_info["admitted"]
    assert_empty starter(limit: 2, waiting: 3).call(items), "a released follow-up is never held again"
  end

  test "no limit set means nothing is held" do
    @writer.add(SLUG, title: "Second kid", parent: 1)
    starter(limit: nil, waiting: 99).call(items)
    assert_not find(4).held?
    assert_equal [["start", "#{SLUG}:2"]], @jobs, "only the legacy approval-flagged one is started here; the CLI starts its own"
  end

  test "a child typed by the person and follow-ups older than the feature are never held" do
    @writer.add(SLUG, title: "Typed", parent: 1, by: "person")
    @writer.add(SLUG, title: "Old", parent: 1)
    @writer.update(SLUG, 5) { |i| i["createdAt"] = (2.days.ago.to_f * 1000).to_i }
    changed = starter(limit: 1, waiting: 5).call(items)
    assert_equal [2], changed.map(&:n)
    assert_not find(4).held?
    assert_not find(5).held?
  end

  test "a nice-to-have never starts by itself; the person starts or drops it" do
    @writer.add(SLUG, title: "Polish", parent: 1, priority: "nice")
    @writer.update(SLUG, 4) { |i| i["awaitingApproval"] = true }
    changed = starter.call(items)
    assert_equal [2], changed.map(&:n)
    assert find(4).to_decide?
    assert_equal "Suggested: start or drop", WorkQueue::Flow.new(find(4)).label
    batch = WorkQueue::Inbox.batches_for(items).sole
    assert_equal [1, [4]], [batch.parent.n, batch.suggested.map(&:n)]

    starter.start_now(find(4))
    assert_includes @jobs, ["start", "#{SLUG}:4"]
    assert_not find(4).to_decide?
    @writer.add(SLUG, title: "More polish", parent: 1, priority: "nice")
    starter.drop(find(5))
    assert_equal "dropped", find(5).status
  end

  test "follow-ups start without approval on the server; root items still wait" do
    started = starter.call(@store.items_for(SLUG))
    assert_equal [2], started.map(&:n)
    kid = @store.find("#{SLUG}:2")
    assert_not kid.awaiting_approval
    assert_equal "queued", kid.status
    assert_equal [["start", "#{SLUG}:2"]], @jobs
    assert @store.find("#{SLUG}:3").awaiting_approval
    assert_empty starter.call(@store.items_for(SLUG)), "idempotent once the flag is cleared"
  end

  test "a listening CLI session is told to start it instead" do
    FakeDispatcher.listening = true
    starter.call(@store.items_for(SLUG))
    assert_equal [2], FakeDispatcher.sent
    assert_empty @jobs
  end
end
