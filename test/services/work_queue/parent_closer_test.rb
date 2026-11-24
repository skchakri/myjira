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

  def close = WorkQueue::ParentCloser.new(writer: @writer).call(@store.items_for(SLUG)).map(&:n)
  def parent = @store.items_for(SLUG).find { |i| i.n == 1 }

  test "closes a grouping parent once every child step is finished" do
    @writer.set_status(SLUG, 2, "done")
    assert_empty close, "one child step is still open"
    @writer.set_status(SLUG, 3, "dropped")
    assert_equal [1], close
    assert_equal "done", parent.status
    assert(parent.log.any? { |l| l["text"].match?(/Closed by itself/) })
  end

  test "leaves a parent with its own branch, PR or open question alone" do
    @writer.set_status(SLUG, 2, "done")
    @writer.set_status(SLUG, 3, "done")
    @writer.update(SLUG, 1) { |i| i["branch"] = "wq/1-parent" }
    assert_empty close
    @writer.update(SLUG, 1) { |i| i.delete("branch"); i["pr"] = "https://github.com/o/r/pull/3" }
    assert_empty close
    assert_equal "review", parent.status
  end

  test "does not close when every child was dropped or folded" do
    @writer.set_status(SLUG, 2, "dropped")
    @writer.set_status(SLUG, 3, "merged")
    assert_empty close
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
