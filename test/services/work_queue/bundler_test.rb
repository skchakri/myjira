require "test_helper"

class WorkQueueBundlerTest < ActiveSupport::TestCase
  SLUG = "home-me-app".freeze

  # Pretend git/gh: tracks which branches are merged into the bundle branch;
  # the test command is red while any branch in `bad` is merged.
  class FakeShell
    attr_reader :calls, :merged

    def initialize(bad: [], conflict: [])
      @bad = bad
      @conflict = conflict
      @merged = []
      @calls = []
    end

    def call(_cwd, *cmd)
      @calls << cmd
      case cmd
      in ["git", "checkout", "-B", *] then @merged = []
      in ["git", "merge", "--no-ff", "--no-edit", ref]
        br = ref.delete_prefix("origin/")
        return ["CONFLICT", false] if @conflict.include?(br)

        @merged << br
      in ["git", "diff", *] then return ["src/x.rb\n", true]
      in ["sh", "-c", _] then return ["", (@merged & @bad).empty?]
      in ["gh", "pr", "create", *] then return ["https://github.com/me/app/pull/42\n", true]
      else nil
      end
      ["", true]
    end
  end

  setup do
    @dir = Dir.mktmpdir("wq")
    @writer = WorkQueue::QueueWriter.new(dir: @dir)
    @store = WorkQueue::Store.new(dir: @dir)
  end

  teardown { FileUtils.rm_rf(@dir) }

  def add(title, parent: nil, status: "review", ready: true)
    item = @writer.add(SLUG, title: title, parent: parent)
    @writer.update(SLUG, item["n"]) do |i|
      i.delete("awaitingApproval")
      i["status"] = status
      i["branch"] = "wq/#{item['n']}"
      i["readyToBundle"] = true if ready
    end
    item["n"]
  end

  def bundler(shell, resolver: ->(*) { false })
    WorkQueue::Bundler.new(store: @store, writer: @writer, logger: Logger.new(nil), shell: shell, resolver: resolver,
                           repo_for: ->(_) { "/repo" }, commands: ->(_) { ["bin/rails test"] })
  end

  def items = @store.items_for(SLUG).index_by(&:n)

  test "waits until the root and every descendant are ready, ignoring dropped ones" do
    root = add("Root thing")
    kid = add("Kid", parent: root, status: "running", ready: false)
    add("Gone", parent: kid, status: "dropped", ready: false)
    shell = FakeShell.new
    bundler(shell).tick
    assert_empty shell.calls

    @writer.update(SLUG, kid) do |i|
      i["status"] = "review"
      i["readyToBundle"] = true
    end
    bundler(shell).tick
    pr = shell.calls.find { |c| c[0..2] == %w[gh pr create] }
    assert_equal "bundle/1-root-thing", pr[pr.index("--head") + 1]
    body = pr[pr.index("--body") + 1]
    assert_includes body, "#1 Root thing"
    assert_includes body, "#2 Kid"
    [root, kid].each do |n|
      assert_equal "https://github.com/me/app/pull/42", items[n].pr
      assert_not items[n].ready_to_bundle?
      assert_equal 1, items[n].bundle_info["root"]
    end
    assert_equal "Bundled → PR #42", WorkQueue::Flow.new(items[kid]).label
  end

  test "bisects out the item that turns the suite red and ships the rest" do
    root = add("Root")
    a = add("A", parent: root)
    b = add("B", parent: root)
    add("C", parent: b)
    bundler(FakeShell.new(bad: ["wq/#{a}"])).tick
    assert_equal "blocked", items[a].status
    assert items[a].bundle_failed?
    assert_equal "Left out of bundle", WorkQueue::Flow.new(items[a]).label
    [root, b, 4].each { |n| assert_equal "https://github.com/me/app/pull/42", items[n].pr }
  end

  test "an unresolvable conflict leaves that item out" do
    root = add("Root")
    kid = add("Kid", parent: root)
    shell = FakeShell.new(conflict: ["wq/#{kid}"])
    bundler(shell).tick
    assert_includes items[kid].bundle_info["failed"], "Merge conflict"
    assert_equal "https://github.com/me/app/pull/42", items[root].pr
    assert(shell.calls.any? { |c| c == ["git", "merge", "--abort"] })
  end

  test "a resolved conflict is committed and kept" do
    root = add("Root")
    kid = add("Kid", parent: root)
    shell = FakeShell.new(conflict: ["wq/#{kid}"])
    shell.define_singleton_method(:call) do |cwd, *cmd|
      cmd[0..1] == %w[git diff] ? ["", true] : super(cwd, *cmd)
    end
    bundler(shell, resolver: ->(*) { true }).tick
    assert_equal "https://github.com/me/app/pull/42", items[kid].pr
  end

  test "a child finishing while the parent's PR is open joins that same bundle branch and PR" do
    root = add("Root thing")
    bundler(FakeShell.new).tick
    kid = add("Late child", parent: root)
    shell = FakeShell.new
    bundler(shell).tick
    assert_includes shell.calls, ["git", "worktree", "add", "--detach", "/repo-bundle-1", "origin/bundle/1-root-thing"]
    assert_includes shell.calls, ["git", "push", "-u", "origin", "bundle/1-root-thing"]
    assert_not(shell.calls.any? { |c| c.include?("--force") && c[1] == "push" })
    assert_equal "https://github.com/me/app/pull/42", items[kid].pr
    assert_equal "bundle/1-root-thing", items[kid].bundle_info["branch"]
  end

  test "a child added after the parent's PR merged gets its own bundle" do
    root = add("Root thing")
    bundler(FakeShell.new).tick
    @writer.set_status(SLUG, root, "done")
    add("Late child", parent: root)
    shell = FakeShell.new
    bundler(shell).tick
    pr = shell.calls.find { |c| c[0..2] == %w[gh pr create] }
    assert_equal "bundle/1-root-thing-2", pr[pr.index("--head") + 1]
    assert_not_includes pr[pr.index("--body") + 1], "#1 Root thing"
  end

  test "ship_now bundles the ready members without waiting for the rest" do
    root = add("Root")
    add("Busy", parent: root, status: "running", ready: false)
    shell = FakeShell.new
    bundler(shell).tick
    assert_empty shell.calls

    bundler(shell).ship_now("#{SLUG}:#{root}")
    assert_equal "https://github.com/me/app/pull/42", items[root].pr
    assert_nil items[2].pr
  end

  test "ready items get a Ready to bundle chip" do
    add("Root")
    f = WorkQueue::Flow.new(items[1])
    assert_equal "Ready to bundle", f.label
    assert_includes f.tags, "bundle"
    assert_includes WorkQueue::Flow::FILTERS.map(&:first), "bundle"
  end
end
