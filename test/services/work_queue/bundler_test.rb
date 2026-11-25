require "test_helper"

class WorkQueueBundlerTest < ActiveSupport::TestCase
  SLUG = "home-me-app".freeze

  # Pretend git/gh: tracks which branches are merged into the bundle branch;
  # the test command is red while any branch in `bad` is merged, or always when `red_base`.
  class FakeShell
    attr_reader :calls, :merged, :cwds
    attr_accessor :red_base

    def initialize(bad: [], conflict: [], red_base: false, tracked: [])
      @bad = bad
      @red_base = red_base
      @tracked = tracked
      @conflict = conflict
      @merged = []
      @calls = []
      @cwds = []
    end

    def call(cwd, *cmd)
      @calls << cmd
      @cwds << cwd
      case cmd
      in ["git", "checkout", "-B" | "--detach", *] then @merged = []
      in ["git", "check-ignore", "-q", rel] then return ["", @tracked.exclude?(rel)]
      in ["git", "merge", "--no-ff", "--no-edit", ref]
        br = ref.delete_prefix("origin/")
        return ["CONFLICT", false] if @conflict.include?(br)

        @merged << br
      in ["git", "diff", *] then return ["src/x.rb\n", true]
      in ["sh", "-c", _]
        return ["", true] if !@red_base && (@merged & @bad).empty?

        return ["...E..\n\nError:\nFooTest#test_x:\nBoom: no tailwind.css\n\n9 runs, 1 errors\n", false]
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

  def bundler(shell, resolver: ->(*) { false }, repo: "/repo")
    WorkQueue::Bundler.new(store: @store, writer: @writer, logger: Logger.new(nil), shell: shell, resolver: resolver,
                           repo_for: ->(_) { repo }, commands: ->(_) { ["bin/rails test"] })
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

  test "a child in a different repo gets its own PR instead of joining the parent's bundle" do
    root = add("Root thing")
    kid = add("Other repo kid", parent: root)
    @writer.update(SLUG, kid) { |i| i["repo"] = "/other" }
    shell = FakeShell.new
    bundler(shell).tick

    creates = shell.calls.each_index.select { |x| shell.calls[x][0..2] == %w[gh pr create] }
    assert_equal 2, creates.size
    heads = creates.to_h { |x| [shell.cwds[x], shell.calls[x][shell.calls[x].index("--head") + 1]] }
    assert_equal({ "/other-bundle-2" => "bundle/2-other-repo-kid", "/repo-bundle-1" => "bundle/1-root-thing" }, heads)
    assert_equal({ "root" => kid, "branch" => "bundle/2-other-repo-kid", "pr" => "https://github.com/me/app/pull/42", "size" => 1 },
                 items[kid].bundle)
    assert_equal 1, items[root].bundle["size"]
  end

  def logs(n) = items[n].log.map { |l| l["text"] }

  def runs(shell) = shell.calls.count { |c| c[0..1] == %w[sh -c] }

  test "a red base blames nobody: items stay ready with the reason in their log" do
    root = add("Root")
    kid = add("Kid", parent: root)
    shell = FakeShell.new(red_base: true)
    b = bundler(shell)
    b.tick

    assert_includes shell.calls, ["git", "checkout", "--detach", "origin/main"]
    assert_not(shell.calls.any? { |c| c[0..1] == %w[gh pr] || c[0..1] == %w[git push] })
    [root, kid].each do |n|
      assert_equal "review", items[n].status
      assert items[n].ready_to_bundle?
      assert_empty items[n].bundle_info
      reason = logs(n).last
      assert_includes reason, "no item is blamed"
      assert_includes reason, "base (origin/main) is red"
      assert_includes reason, "`bin/rails test` failed: Error: | FooTest#test_x: | Boom: no tailwind.css | 9 runs, 1 errors"
    end

    # Same base commit: not run again on the next tick, and "Ready for PR" retries without repeating the log line.
    count = runs(shell)
    lines = logs(kid).size
    b.tick
    assert_equal count, runs(shell)
    b.ship_now("#{SLUG}:#{kid}")
    assert_operator runs(shell), :>, count
    assert_equal lines, logs(kid).size

    # Once the base is green the same items ship.
    shell.red_base = false
    b.ship_now("#{SLUG}:#{kid}")
    [root, kid].each { |n| assert_equal "https://github.com/me/app/pull/42", items[n].pr }
  end

  test "a red base still leaves out a member that cannot be merged" do
    root = add("Root")
    kid = add("Kid", parent: root)
    bundler(FakeShell.new(red_base: true, conflict: ["wq/#{kid}"])).tick
    assert_includes items[kid].bundle_info["failed"], "Merge conflict"
    assert items[root].ready_to_bundle?
    assert_equal "review", items[root].status
  end

  test "a blamed member keeps the tail of the failing output" do
    root = add("Root")
    kid = add("Kid", parent: root)
    bundler(FakeShell.new(bad: ["wq/#{kid}"])).tick
    assert_equal "blocked", items[kid].status
    why = "Breaks the bundle's test/lint run: `bin/rails test` failed: Error: | FooTest#test_x: | Boom: no tailwind.css | 9 runs, 1 errors"
    assert_equal why, items[kid].bundle_info["failed"]
    assert_includes logs(kid), "Left out of bundle ##{root}: #{why}"
    assert_equal "https://github.com/me/app/pull/42", items[root].pr
  end

  test "the bundle worktree gets the repo's git-ignored files the suite needs" do
    repo = File.join(@dir, "app")
    tree = "#{repo}-bundle-1"
    [repo, tree].each { |d| FileUtils.mkdir_p([File.join(d, "config"), File.join(d, "app/assets/builds")]) }
    %w[config/master.key app/assets/builds/tailwind.css .env config/database.yml].each { |rel| File.write(File.join(repo, rel), "x") }
    File.write(File.join(repo, "app/assets/builds/.keep"), "")
    add("Root")
    bundler(FakeShell.new(tracked: [".env"]), repo: repo).tick

    %w[config/master.key app/assets/builds/tailwind.css].each do |rel|
      assert_equal File.join(repo, rel), File.readlink(File.join(tree, rel))
    end
    %w[.env config/database.yml app/assets/builds/.keep].each { |rel| assert_not File.exist?(File.join(tree, rel)), rel }
  end

  test "a repo homey's release train batches skips the local suite and bisect, and ships the bundle" do
    root = add("Root")
    a = add("A", parent: root)
    shell = FakeShell.new(bad: ["wq/#{a}"], red_base: true)
    WorkQueue::Bundler.new(store: @store, writer: @writer, logger: Logger.new(nil), shell: shell, resolver: ->(*) { false },
                           repo_for: ->(_) { "/repo" }, commands: ->(_) { ["bin/rails test"] }, batched: ->(repo) { repo == "/repo" }).tick
    assert_empty(shell.calls.select { |c| c[0] == "sh" })
    pr = shell.calls.find { |c| c[0..2] == %w[gh pr create] }
    assert_not_includes pr, "--draft"
    assert_includes pr[pr.index("--body") + 1], "homey's release train"
    [root, a].each { |n| assert_equal "https://github.com/me/app/pull/42", items[n].pr }
    assert_match(/release train tests it/, items[a].log.map { |l| l["text"] }.join("\n"))
  end

  test "the repo's origin remote decides whether homey batches it" do
    shell = ->(_, *cmd) { cmd == %w[git remote get-url origin] ? ["git@github.com:skchakri/ownsites.git\n", true] : ["", true] }
    b = WorkQueue::Bundler.new(store: @store, writer: @writer, logger: Logger.new(nil), shell: shell)
    WorkQueue::HomeyTrain.stub(:batched_repos, Set["skchakri/ownsites"]) { assert b.send(:homey_batched?, "/repo") }
    WorkQueue::HomeyTrain.stub(:batched_repos, Set["skchakri/homey"]) { assert_not b.send(:homey_batched?, "/repo") }
  end
end
