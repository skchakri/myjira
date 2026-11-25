require "test_helper"

class WorkQueueParentCloserTest < ActiveSupport::TestCase
  SLUG = "home-me-app".freeze

  setup do
    @dir = Dir.mktmpdir("wq")
    @writer = WorkQueue::QueueWriter.new(dir: @dir)
    @store = WorkQueue::Store.new(dir: @dir)
    @writer.add(SLUG, title: "Parent")
    @writer.add(SLUG, title: "Kid A", parent: 1)
    @writer.add(SLUG, title: "Kid B", parent: 1)
    @writer.set_status(SLUG, 1, "review")
  end

  teardown { FileUtils.rm_rf(@dir) }

  def parent = @store.items_for(SLUG).find { |i| i.n == 1 }

  test "children_done? needs every legacy child finished and one actually done" do
    kids = -> { @store.items_for(SLUG).reject { |i| i.n == 1 } }
    @writer.set_status(SLUG, 2, "done")
    assert_not WorkQueue::ParentCloser.children_done?(kids.call)
    @writer.set_status(SLUG, 3, "dropped")
    assert WorkQueue::ParentCloser.children_done?(kids.call)
  end

  test "flow says there is nothing to merge instead of asking for a review" do
    @writer.update(SLUG, 1) { |i| i["branch"] = "wq/1-parent" } # not auto-closed, so the label is what shows
    @writer.set_status(SLUG, 2, "done")
    @writer.set_status(SLUG, 3, "done")
    flow = WorkQueue::ItemContext.new(parent, store: @store).flow
    assert_equal "All child steps done", flow.label
    assert_not_includes flow.tags, "you"
    assert_match(/Nothing to merge/, flow.your_part)
  end
end
