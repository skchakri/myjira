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

  def starter
    WorkQueue::ChildStarter.new(writer: @writer, dispatcher: FakeDispatcher, enqueue: ->(action, key) { @jobs << [action, key] })
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
