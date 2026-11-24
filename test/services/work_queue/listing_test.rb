require "test_helper"

class WorkQueueListingTest < ActiveSupport::TestCase
  SLUG = "home-me-app".freeze

  setup do
    @dir = Dir.mktmpdir("wq")
    @path = File.join(@dir, "#{SLUG}.json")
    @store = WorkQueue::Store.new(dir: @dir)
    @old = ENV["WORK_QUEUE_DIR"]
    ENV["WORK_QUEUE_DIR"] = @dir
  end

  teardown do
    ENV["WORK_QUEUE_DIR"] = @old
    FileUtils.rm_rf(@dir)
  end

  # 1..8 finished roots (8 newest), 9 finished parent of open 10, 11 finished child of 9, 12 folded.
  def write(extra = [])
    done = (1..8).map { |n| { n: n, title: "Done #{n}", status: "done", questions: [], log: [], updatedAt: n * 1000 } }
    File.write(@path, { items: done + [
      { n: 9, title: "Shipped parent", status: "done", questions: [], log: [], updatedAt: 1 },
      { n: 10, title: "Open kid", status: "queued", parent: 9, questions: [], log: [] },
      { n: 11, title: "Done kid", status: "done", parent: 9, questions: [], log: [], updatedAt: 9000 },
      { n: 12, title: "Folded", status: "merged", mergedInto: 9, questions: [], log: [], updatedAt: 2 }
    ] + extra }.to_json)
    @store.items_for(SLUG)
  end

  def listing(**opts) = WorkQueue::Listing.new(SLUG, write, store: @store, **opts)

  test "draws open work, the finished parents above it and the five newest finished roots" do
    l = listing
    assert_equal [4, 5, 6, 7, 8, 9, 10].to_set, l.shown
    assert_equal 5, l.older_count # 1, 2, 3, the finished kid 11 and the folded 12
    assert_not l.all?
    assert_equal [10], l.children[9].map(&:n), "the tree stays connected and leaves the finished sibling out"
  end

  test "all: true draws everything and keeps the same older count" do
    l = listing(all: true)
    assert_equal 12, l.shown.size
    assert_equal 5, l.older_count
    assert l.all?
    assert_equal [10, 11].to_set, l.children[9].to_set(&:n)
  end

  test "the selected item is drawn with its parents even when old" do
    assert_includes listing(selected: "#{SLUG}:11").shown, 11
    assert_includes listing(selected: "#{SLUG}:1").shown, 1
    assert_not_includes listing(selected: "other-project:1").shown, 1
  end

  test "counts and progress cover every item, drawn or not" do
    l = listing
    assert_equal 1, l.counts["all"]            # one open item
    assert_equal 10, l.counts["ok"]            # every finished one, most of them not drawn
    assert_equal 1, l.counts["closed"]
    assert_equal 1, l.open_count
    assert_equal 10, l.done_count
    roll = l.progress.for(l.items.find { |i| i.n == 9 })
    assert_equal 2, roll.total, "the hidden finished child still counts in its parent's rollup"
    assert_equal 1, roll.done
  end

  test "a store re-reads a file that changed and reuses an unchanged parse" do
    write
    settled = 10.seconds.ago.to_time
    File.utime(settled, settled, @path)
    first = @store.items_for(SLUG)
    calls = 0
    @store.stub(:parse, ->(_) { calls += 1; [] }) { assert_equal 12, @store.items_for(SLUG).size }
    assert_equal 0, calls, "an unchanged file is not parsed again"
    first.first.title = "mutated by a caller"
    assert_equal "Done 1", @store.items_for(SLUG).first.title, "callers get their own copies"

    write([{ n: 13, title: "New", status: "queued", questions: [], log: [] }])
    assert_equal 13, @store.items_for(SLUG).size
  end

  test "watcher sends card updates for a status change and redraws the block only when the tree changes" do
    write
    watcher = WorkQueue::Watcher.new(store: @store, queues: @dir, projects: Dir.mktmpdir("wqp"), logger: Logger.new(File::NULL),
                                     child_starter: Class.new { def call(_) = [] }.new)
    watcher.prime
    seen = []
    record = ->(kind) { ->(*args, **kw) { seen << [kind, args, kw] } }
    run = lambda do |items|
      File.write(@path, { items: items }.to_json)
      seen.clear
      WorkQueue::Broadcaster.stub(:project_changed, record.(:project)) do
        WorkQueue::Broadcaster.stub(:items_changed, record.(:items)) { watcher.queue_changed([@path]) }
      end
      seen.dup
    end
    base = JSON.parse(File.read(@path))["items"]

    started = base.map { |h| h["n"] == 10 ? h.merge("status" => "running") : h }
    out = run.(started)
    assert_equal [:items], out.map(&:first), "a status change is a card update, not a block redraw"
    assert_equal [10], out.first[1].first.map(&:n)
    assert_equal [[10, "pending"]], out.first[2][:transitions].map { |i, from| [i.n, from] }

    assert_empty run.(started), "nothing changed, nothing sent"

    added = started + [{ "n" => 13, "title" => "New", "status" => "queued", "questions" => [], "log" => [] }]
    out = run.(added)
    assert_equal [:project], out.map(&:first), "a new item redraws the block"
    assert_equal [13], out.first[2][:changed].map(&:n), "only the changed item gets a fresh detail header"

    moved = added.map { |h| h["n"] == 13 ? h.merge("parent" => 9) : h }
    assert_equal [:project], run.(moved).map(&:first), "moving an item under another parent redraws the block"

    reopened = moved.map { |h| h["n"] == 1 ? h.merge("status" => "queued") : h }
    assert_equal [:project], run.(reopened).map(&:first), "a reopened finished item may not be in the page"
  end

  test "status refresh skips git when the worktree's refs did not move, and gh until its interval is up" do
    redis = WorkQueue::RunState.redis
    redis.scan_each(match: "#{WorkQueue::RunState::PREFIX}:*") { |k| redis.del(k) }
    WorkQueue::StatusCache::MEMO.each_value(&:clear)
    File.write(@path, { items: [{ n: 1, title: "Open", status: "review", pr: "https://github.com/o/r/pull/1", questions: [], log: [] }] }.to_json)
    item = @store.find("#{SLUG}:1")
    fetches = 0
    computes = 0
    prs = Struct.new(:hit) { def fetch(_) = hit.call }.new(-> { fetches += 1; nil })
    delivery = Class.new { def compute(_) = nil }.new
    sig = "refs-v1"
    now = Time.current
    refresh = ->(at, **opts) { WorkQueue::StatusCache.refresh(item, store: @store, prs: prs, delivery: delivery, now: at, **opts) }
    WorkQueue::GitInfo.stub(:signature, ->(_) { sig }) do
      WorkQueue::GitInfo.stub(:compute, ->(*, **) { computes += 1; nil }) do
        refresh.(now)
        refresh.(now + 20)
        assert_equal [1, 1], [fetches, computes], "second sweep: nothing re-read"
        refresh.(now + 61)
        assert_equal [2, 1], [fetches, computes], "the PR is re-read after a minute"
        sig = "refs-v2"
        refresh.(now + 62)
        assert_equal [2, 2], [fetches, computes], "git is recomputed once the refs move"
        refresh.(now + 63, force: true)
        assert_equal [3, 3], [fetches, computes]
      end
    end
  end
end
