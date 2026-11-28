require "test_helper"

# A new item branch was cut from the local main without fetching, so a checkout
# whose main was far behind origin had the agent redo work already delivered.
class WorkQueueSupervisorWorktreeTest < ActiveSupport::TestCase
  SLUG = "home-me-x".freeze
  KEY = "#{SLUG}:1".freeze

  setup do
    @tmp = Dir.mktmpdir("wq-wt")
    @dir = File.join(@tmp, "queue")
    FileUtils.mkdir_p(@dir)
    @writer = WorkQueue::QueueWriter.new(dir: @dir)
    @store = WorkQueue::Store.new(dir: @dir)
    redis = WorkQueue::RunState.redis
    redis.scan_each(match: "#{WorkQueue::RunState::PREFIX}:*") { |k| redis.del(k) }
    @writer.add(SLUG, title: "Fix the thing")
    @sup = WorkQueue::Supervisor.new(store: @store, writer: @writer, logger: Logger.new(nil))

    @origin = File.join(@tmp, "origin.git")
    @repo = File.join(@tmp, "repo")
    sh(@tmp, "git", "init", "-q", "--bare", "-b", "main", @origin)
    sh(@tmp, "git", "clone", "-q", @origin, @repo)
    commit(@repo, "first")
    sh(@repo, "git", "push", "-q", "origin", "HEAD:main")
    @stale = head(@repo)
  end

  teardown { FileUtils.rm_rf(@tmp) }

  def sh(cwd, *cmd)
    out, status = Open3.capture2e(*cmd, chdir: cwd)
    raise "#{cmd.join(' ')}: #{out}" unless status.success?

    out
  end

  def commit(repo, msg)
    sh(repo, "git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", msg)
  end

  def head(dir) = sh(dir, "git", "rev-parse", "HEAD").strip

  # Someone else pushes to origin/main; the local main is not updated.
  def advance_origin
    other = File.join(@tmp, "other")
    sh(@tmp, "git", "clone", "-q", @origin, other)
    commit(other, "delivered elsewhere")
    sh(other, "git", "push", "-q", "origin", "HEAD:main")
    head(other)
  end

  def ensure_worktree = @sup.send(:ensure_worktree, @store.find(KEY), { "repo" => @repo })

  test "a new item branch starts from origin/main after fetching, not the stale local main" do
    fresh = advance_origin

    path = ensure_worktree

    assert_equal "#{@repo}-wq-1", path
    assert_equal fresh, head(path)
    assert_equal @stale, sh(@repo, "git", "rev-parse", "main").strip, "the local main is left alone"
    _, upstream = Open3.capture2e("git", "rev-parse", "--abbrev-ref", "@{upstream}", chdir: path)
    assert_not upstream.success?, "the item branch must not track origin/main"
  end

  test "a fetch that fails falls back to what is there and logs it on the item" do
    sh(@repo, "git", "remote", "set-url", "origin", File.join(@tmp, "gone.git"))

    path = ensure_worktree

    assert_equal @stale, head(path)
    assert(@store.find(KEY).log.any? { |l| l["text"].include?("git fetch origin failed") })
  end

  test "a repo with no origin branches from the local main without logging a fetch failure" do
    sh(@repo, "git", "remote", "remove", "origin")

    path = ensure_worktree

    assert_equal @stale, head(path)
    assert(@store.find(KEY).log.none? { |l| l["text"].include?("fetch") })
  end
end
