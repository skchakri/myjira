require "test_helper"

class WorkQueueWorktreeQueuesTest < ActiveSupport::TestCase
  PARENT = "home-me-app".freeze
  STRAY = "home-me-app-wq-2".freeze

  setup do
    @dir = Dir.mktmpdir("wq")
    @writer = WorkQueue::QueueWriter.new(dir: @dir)
    @store = WorkQueue::Store.new(dir: @dir)
    @folder = WorkQueue::WorktreeQueues.new(dir: @dir, writer: @writer)
    @writer.add(PARENT, title: "First")
    @writer.add(PARENT, title: "Second")
    @writer.add(PARENT, title: "Third")
  end

  teardown { FileUtils.rm_rf(@dir) }

  def write(slug, items) = File.write(File.join(@dir, "#{slug}.json"), JSON.pretty_generate("items" => items))

  def raw(n, title, extra = {})
    { "n" => n, "title" => title, "description" => "about #{title}", "status" => "triage", "questions" => [{ "q" => "Which?", "at" => 5 }],
      "log" => [{ "at" => 1, "text" => "Added" }], "createdAt" => 1000 + n, "updatedAt" => 1000 + n }.merge(extra)
  end

  def parent_items = @store.items_for(PARENT)
  def exist?(slug) = File.exist?(File.join(@dir, "#{slug}.json"))

  test "moves a wq worktree's items into the parent queue, renumbered and filed under the item it worked on" do
    write(STRAY, [raw(1, "Stray one"), raw(2, "Stray two", "status" => "running", "agent" => "abc"), raw(3, "Kid of one", "parent" => 1)])

    folds = @folder.call

    assert_equal 1, folds.size
    fold = folds.first
    assert_equal [STRAY, PARENT, 3, 0, 2], [fold.slug, fold.parent, fold.moved, fold.skipped, fold.under]
    assert_equal [1, 2, 3, 4, 5, 6], parent_items.map(&:n)
    one, two, kid = parent_items.last(3)
    assert_equal ["Stray one", "about Stray one", "triage", 2], [one.title, one.description, one.status, one.parent]
    assert_equal ["Which?"], one.questions.map(&:q)
    assert_equal({ "priority" => "nice" }, one.follow_up, "an unstarted moved item waits for the person, it never starts by itself")
    assert one.to_decide?
    assert_equal ["running", 2, nil], [two.status, two.parent, two.follow_up], "a started item keeps running as it was"
    assert_equal 4, kid.parent, "a parent inside the stray file follows its item's new number"
    assert_equal "Added", one.log.first["text"]
    assert_match(/Moved here from the worktree queue #{STRAY} \(was #1 there\); filed as a follow-up of #2/, one.log.last["text"])
    assert_not exist?(STRAY), "the stray file is gone from the queues folder"
    assert_equal File.join(@dir, "archive", "#{STRAY}.json"), fold.archive
    assert_equal 3, JSON.parse(File.read(fold.archive))["items"].size, "the archive keeps the original file"
    assert_not File.exist?(File.join(@dir, "#{STRAY}.json.lock"))
  end

  test "folding twice changes nothing, and a stray file that comes back is not added again" do
    write(STRAY, [raw(1, "Stray one")])
    @folder.call
    assert_empty @folder.call
    assert_equal 4, parent_items.size

    write(STRAY, [raw(1, "Stray one"), raw(2, "New since")])
    fold = @folder.call.first

    assert_equal [1, 1], [fold.moved, fold.skipped]
    assert_equal ["First", "Second", "Third", "Stray one", "New since"], parent_items.map(&:title)
    assert_not_equal File.join(@dir, "archive", "#{STRAY}.json"), fold.archive, "an earlier archive is never overwritten"
    assert_equal 2, Dir.glob(File.join(@dir, "archive", "*.json")).size
  end

  test "items stay top level when the parent queue has no such item" do
    write("home-me-app-wq-99", [raw(1, "Orphan")])
    fold = @folder.call.first
    assert_nil fold.under
    assert_equal [nil, nil], [parent_items.last.parent, parent_items.last.follow_up]
  end

  test "folds a .claude/worktrees queue into its repo" do
    write("home-me-app-claude-worktrees-agent-a1b2", [raw(1, "From an agent worktree")])
    fold = @folder.call.first
    assert_equal [PARENT, 1, nil], [fold.parent, fold.moved, fold.under]
    assert_equal "From an agent worktree", parent_items.last.title
  end

  test "resolves the parent through a myjira project when it has no queue file yet" do
    Project.create!(slug: "fresh", name: "Fresh", repo_path: "/home/me/fresh")
    write("home-me-fresh-wq-4", [raw(1, "First ever")])
    fold = @folder.call.first
    assert_equal "home-me-fresh", fold.parent
    assert_equal ["First ever"], @store.items_for("home-me-fresh").map(&:title)
  end

  test "a worktree's slug maps to the parent repo's path" do
    Project.create!(slug: "fresh", name: "Fresh", repo_path: "/home/me/fresh")
    repo_for = WorkQueue::Workspace.method(:repo_for)

    assert_equal "/home/me/fresh", repo_for.call("home-me-fresh")
    assert_equal "/home/me/fresh", repo_for.call("home-me-fresh-wq-4")
    assert_equal "/home/me/fresh", repo_for.call("home-me-fresh-claude-worktrees-agent-a1b2")
    assert_equal "/home/me/fresh", repo_for.call("home-me-fresh-wq-4-claude-worktrees-agent-a1b2")
    assert_nil repo_for.call("home-me-other-wq-4"), "no project for the parent: nothing to map to"
    assert_nil repo_for.call("home-me-fresh-wq"), "not a worktree's slug"

    WorkQueue::Current.repos = WorkQueue::Workspace.repos
    assert_equal "/home/me/fresh", repo_for.call("home-me-fresh-wq-4"), "also through the per-request memo"
  end

  test "a project still saved on a worktree path maps to the parent repo" do
    Project.create!(slug: "fresh", name: "Fresh", repo_path: "/home/me/fresh")
    Project.create!(slug: "stray", name: "Stray", repo_path: "/home/me/elsewhere").update_column(:repo_path, "/home/me/fresh/.claude/worktrees/agent-a1b2")

    assert_equal "/home/me/fresh", WorkQueue::Workspace.repo_for("home-me-fresh-claude-worktrees-agent-a1b2")
  end

  test "leaves alone slugs that only look like a worktree" do
    lookalikes = %w[home-me-other-wq-7 home-me-app-wq home-me-app-wq-2x home-me-nothing-claude-worktrees-x home-me-app-worktrees-x]
    lookalikes.each { |slug| write(slug, [raw(1, slug)]) }

    assert_empty @folder.call
    lookalikes.each do |slug|
      assert exist?(slug), "#{slug} was touched"
      assert_nil WorkQueue::WorktreeQueues.origin(slug, dir: @dir)
    end
    assert_equal 3, parent_items.size
    assert_equal lookalikes.sort, (@store.projects.keys - [PARENT]).sort, "they are still projects of their own"
  end

  test "a file that cannot be parsed is left for the next sweep" do
    File.write(File.join(@dir, "#{STRAY}.json"), "{ half")
    assert_empty @folder.call
    assert exist?(STRAY)
  end

  test "the store never lists a worktree queue as a project, even before the fold" do
    write(STRAY, [raw(1, "Stray one")])
    write("home-me-app-claude-worktrees-agent-a1b2", [raw(1, "Other")])

    assert_equal [PARENT], @store.projects.keys
    assert_equal ["First", "Second", "Third"], @store.all.map(&:title)
  end

  test "the watcher folds a worktree queue when its file changes" do
    write(STRAY, [raw(1, "Stray one")])
    watcher = WorkQueue::Watcher.new(store: @store, queues: @dir, projects: Dir.mktmpdir("wq-tr"), logger: Logger.new(IO::NULL),
                                     train_sync: ->(_) { [] })
    watcher.queue_changed([File.join(@dir, "#{STRAY}.json")])

    assert_not exist?(STRAY)
    assert_equal "Stray one", parent_items.last.title
  end
end
