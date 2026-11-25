require "test_helper"
require "open3"

# Runs against real throwaway git repos: a bare "origin" (me/app.git), its main
# checkout (app) and one linked worktree per item (app-wq-<n>).
class WorkQueueWorktreeCleanerTest < ActiveSupport::TestCase
  SLUG = "home-me-app".freeze
  REPO = "me/app".freeze
  GIT_ENV = { "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@example.com", "GIT_COMMITTER_NAME" => "t",
              "GIT_COMMITTER_EMAIL" => "t@example.com", "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_SYSTEM" => File::NULL }.freeze

  setup do
    @tmp = File.realpath(Dir.mktmpdir("wq-clean"))
    @queues = File.join(@tmp, "queues")
    @origin = File.join(@tmp, "me", "app.git")
    @repo = File.join(@tmp, "app")
    FileUtils.mkdir_p([@queues, File.dirname(@origin), @repo])
    sh(@tmp, "git", "init", "-q", "--bare", "-b", "main", @origin)
    sh(@repo, "git", "init", "-q", "-b", "main")
    File.write(File.join(@repo, ".gitignore"), "tmp/\n")
    commit(@repo, "README", "hello")
    sh(@repo, "git", "remote", "add", "origin", @origin)
    sh(@repo, "git", "push", "-q", "-u", "origin", "main")
    sh(@repo, "git", "remote", "set-head", "origin", "main")

    @writer = WorkQueue::QueueWriter.new(dir: @queues)
    @store = WorkQueue::Store.new(dir: @queues)
    @redis = WorkQueue::RunState.redis
    @redis.scan_each(match: "#{WorkQueue::RunState::PREFIX}:*") { |k| @redis.del(k) }
    @redis.set("#{WorkQueue::RunState::PREFIX}:cleanup_since", 1.hour.ago.to_f)
    @open_prs = []
    @busy = {}
    @gh_calls = []
  end

  teardown { FileUtils.rm_rf(@tmp) }

  def sh(dir, *cmd)
    out, status = Open3.capture2e(GIT_ENV, *cmd, chdir: dir)
    raise "#{cmd.join(' ')} failed: #{out}" unless status.success?

    out.strip
  end

  def commit(dir, file, text)
    File.write(File.join(dir, file), text)
    sh(dir, "git", "add", "-A")
    sh(dir, "git", "commit", "-q", "-m", "#{file}: #{text}")
    sh(dir, "git", "rev-parse", "HEAD")
  end

  def tree(n) = "#{@repo}-wq-#{n}"
  def pr_url(n) = "https://github.com/#{REPO}/pull/#{n}"
  def local?(branch) = system(GIT_ENV, "git", "-C", @repo, "rev-parse", "--verify", "-q", "refs/heads/#{branch}", out: File::NULL)
  def remote?(branch) = sh(@repo, "git", "ls-remote", "origin", "refs/heads/#{branch}").present?
  def log_of(n) = @store.items_for(SLUG).find { |i| i.n == n }.log.map { |l| l["text"] }
  def notes(n) = log_of(n).grep(/\ACleanup after deploy/)

  # An item's work: a worktree on its branch with one commit, pushed. Returns the head SHA.
  def work(n, branch, push: true)
    sh(@repo, "git", "worktree", "add", "-q", "-b", branch, tree(n), "main")
    sha = commit(tree(n), "item#{n}.txt", "work")
    sh(tree(n), "git", "push", "-q", "origin", branch) if push
    sha
  end

  # What a squash merge leaves: the change on main as a new commit the branch does not contain.
  def squash(n)
    commit(@repo, "item#{n}.txt", "work")
    sh(@repo, "git", "push", "-q", "origin", "main")
  end

  def item(branch:, pr: nil, status: "done", **extra)
    added = @writer.add(SLUG, title: "Item on #{branch}")
    @writer.update(SLUG, added["n"]) do |i|
      i.delete("awaitingApproval")
      i["status"] = status
      i["branch"] = branch
      i["pr"] = pr_url(pr || added["n"])
      extra.each { |k, v| i[k.to_s] = v }
    end
    @store.items_for(SLUG).find { |i| i.n == added["n"] }
  end

  def pr(item, head_sha, state: "MERGED", head: item.branch, base: "main")
    WorkQueue::PullRequests::Status.new(url: item.pr, number: item.pr_number.to_i, state: state, base: base, head: head,
                                        head_sha: head_sha, merge_sha: nil, merged_at: 10.minutes.ago.iso8601)
  end

  def cache(status, delivery)
    @redis.set(WorkQueue::StatusCache.pr_key(status.url), status.to_h.to_json)
    @redis.set(WorkQueue::StatusCache.delivery_key(status.url), (delivery ? { state: delivery, detail: "x" } : {}).to_json)
  end

  def workflow(name) = @redis.set(WorkQueue::Delivery.summary_key(REPO), { workflow: name, run: nil, at: Time.current.iso8601 }.to_json)

  def cleaner
    gh = lambda do |*args|
      @gh_calls << args
      [@open_prs.to_json, true]
    end
    WorkQueue::WorktreeCleaner.new(store: @store, writer: @writer, logger: Logger.new(File::NULL), repo_for: ->(_) { @repo },
                                   gh: gh, busy: ->(path) { @busy[path] })
  end

  # A delivered item: worktree + pushed branch + squash merge.
  def delivered(branch = nil)
    it = item(branch: branch || "wq/#{@store.items_for(SLUG).size + 1}-work")
    sha = work(it.n, it.branch)
    squash(it.n)
    [it, pr(it, sha)]
  end

  test "a merged item loses its worktree, its local branch and its branch on origin" do
    it, status = delivered
    FileUtils.mkdir_p(File.join(tree(it.n), "tmp"))
    File.write(File.join(tree(it.n), "tmp", "cache"), "ignored files do not count as changes")

    result = cleaner.clean(it, status)

    assert_equal %i[worktree local remote], result.removed.map(&:kind)
    assert result.complete?
    assert_not File.exist?(tree(it.n))
    assert_not local?(it.branch)
    assert_not remote?(it.branch)
    assert_no_match(/wq-#{it.n}/, sh(@repo, "git", "worktree", "list"))
    assert local?("main")
    assert remote?("main")
    assert File.exist?(File.join(@repo, "README"))
  end

  test "a second run finds nothing to do" do
    it, status = delivered
    cleaner.clean(it, status)

    again = cleaner.clean(it, status)

    assert_empty again.steps
    assert again.complete?
    assert_nil again.note
  end

  test "a worktree with uncommitted or untracked changes is left, with its branch" do
    it, status = delivered
    File.write(File.join(tree(it.n), "notes.txt"), "not committed")

    result = cleaner.clean(it, status)

    assert File.exist?(File.join(tree(it.n), "notes.txt"))
    assert local?(it.branch)
    assert_equal ["it has uncommitted or untracked changes", "it is still checked out in a worktree"], result.skipped.map(&:reason)
    assert_not result.complete?
    assert_not remote?(it.branch), "the branch on origin is exactly what was merged, so it goes"
  end

  test "nothing is removed for a pull request that is not merged" do
    it = item(branch: "wq/1-open")
    sha = work(it.n, it.branch)

    result = cleaner.clean(it, pr(it, sha, state: "OPEN"))

    assert_empty result.steps
    assert File.exist?(tree(it.n))
    assert local?(it.branch)
    assert remote?(it.branch)
  end

  test "a local branch with commits the pull request never contained is left, with its worktree" do
    it, status = delivered
    commit(tree(it.n), "later.txt", "made after the merge, never pushed")

    result = cleaner.clean(it, status)

    assert File.exist?(tree(it.n))
    assert local?(it.branch)
    assert_equal %i[worktree local], result.skipped.map(&:kind)
    assert(result.skipped.all? { |s| s.reason == "it has commits the merged pull request never contained" })
    assert_not remote?(it.branch), "origin still holds the PR's head commit, nothing more"
  end

  test "a branch on origin with commits the pull request never contained is left" do
    it, status = delivered
    commit(tree(it.n), "later.txt", "pushed after the merge")
    sh(tree(it.n), "git", "push", "-q", "origin", it.branch)

    result = cleaner.clean(it, status)

    assert remote?(it.branch)
    assert local?(it.branch)
    assert_includes result.skipped.map(&:kind), :remote
  end

  test "the main checkout, the default branch and the branch checked out in the main checkout are never touched" do
    onmain = item(branch: "main")
    head = sh(@repo, "git", "rev-parse", "HEAD")
    result = cleaner.clean(onmain, pr(onmain, head, head: "main", base: "release"))
    assert_equal ["a protected branch, never removed"], result.skipped.map(&:reason).uniq

    sh(@repo, "git", "checkout", "-q", "-b", "wq/9-in-main-checkout")
    sha = commit(@repo, "nine.txt", "work")
    sh(@repo, "git", "push", "-q", "origin", "wq/9-in-main-checkout")
    current = item(branch: "wq/9-in-main-checkout")
    result = cleaner.clean(current, pr(current, sha))

    assert_equal ["a protected branch, never removed"], result.skipped.map(&:reason)
    assert File.exist?(File.join(@repo, "nine.txt"))
    assert local?("wq/9-in-main-checkout")
    assert remote?("wq/9-in-main-checkout")
    assert local?("main")
    assert remote?("main")
  end

  test "a worktree a session is still running in is left" do
    it, status = delivered
    @busy[tree(it.n)] = 4242

    result = cleaner.clean(it, status)

    assert File.exist?(tree(it.n))
    assert local?(it.branch)
    assert_equal "pid 4242", result.skipped.first.detail
  end

  test "the real process check sees a process working inside the worktree" do
    it, = delivered
    pid = spawn("sleep", "30", chdir: tree(it.n))
    sleep 0.1
    assert_equal pid, WorkQueue::WorktreeCleaner.process_in(tree(it.n))
    assert_nil WorkQueue::WorktreeCleaner.process_in(@origin)
  ensure
    Process.kill("TERM", pid) && Process.wait(pid) if pid
  end

  test "a branch on origin that another open pull request uses is left" do
    it, status = delivered
    @open_prs = [{ "number" => 77, "headRefName" => "wq/other", "baseRefName" => it.branch }]

    result = cleaner.clean(it, status)

    assert remote?(it.branch)
    assert_not local?(it.branch)
    assert_equal ["pull request #77 is still open on it"], result.skipped.map(&:reason)
  end

  test "nothing is removed while another open task uses the same branch" do
    it, status = delivered
    other = item(branch: it.branch, pr: 99, status: "review")

    result = cleaner.clean(it, status)

    assert_equal ["task ##{other.n} is still open on the same branch or pull request"], result.skipped.map(&:reason)
    assert File.exist?(tree(it.n))
    assert remote?(it.branch)
  end

  test "a pull request that lives in another repo is none of this repo's business" do
    it, status = delivered
    status.url = "https://github.com/someone/else/pull/1"

    result = cleaner.clean(it, status)

    assert_empty result.steps
    assert_match(/another repo/, result.ignored)
    assert File.exist?(tree(it.n))
    assert remote?(it.branch)
  end

  test "a follow-up shipped in its parent's bundle PR is cleaned with that PR" do
    parent = item(branch: "wq/1-parent", pr: 50)
    work(parent.n, parent.branch)
    child = item(branch: "wq/2-child", pr: 50, parent: parent.n, bundle: { "root" => 1, "branch" => "bundle/1-parent", "pr" => pr_url(50) })
    work(child.n, child.branch)
    sh(@repo, "git", "checkout", "-q", "-b", "bundle/1-parent", "main")
    sh(@repo, "git", "merge", "-q", "--no-ff", "--no-edit", parent.branch)
    sh(@repo, "git", "merge", "-q", "--no-ff", "--no-edit", child.branch)
    head = sh(@repo, "git", "rev-parse", "HEAD")
    sh(@repo, "git", "push", "-q", "origin", "bundle/1-parent")
    sh(@repo, "git", "checkout", "-q", "main")
    squash(parent.n)
    child = @store.items_for(SLUG).find { |i| i.n == child.n }

    result = cleaner.clean(child, pr(child, head, head: "bundle/1-parent"))

    assert result.complete?, result.note
    assert_not File.exist?(tree(child.n))
    [child.branch, "bundle/1-parent"].each do |branch|
      assert_not local?(branch), branch
      assert_not remote?(branch), branch
    end
    assert File.exist?(tree(parent.n)), "the parent's own worktree waits for the parent's own run"
  end

  test "the tick waits for the deploy, then cleans once, logs it on the item and never repeats" do
    it, status = delivered
    workflow("Deploy")
    cache(status, "not_live")
    c = cleaner

    assert_empty c.tick
    assert File.exist?(tree(it.n))

    cache(status, "live")
    assert_equal [it.key], c.tick.map { |r| r.item.key }
    assert_not File.exist?(tree(it.n))
    assert_not local?(it.branch)
    assert_not remote?(it.branch)
    assert_equal 1, notes(it.n).size
    assert_match(/removed worktree .*-wq-#{it.n}, local branch #{it.branch} \(was \h{7}\), origin branch #{it.branch}/, notes(it.n).first)

    assert_empty c.tick
    assert_empty cleaner.tick
    assert_equal 1, notes(it.n).size
    assert_equal 1, @gh_calls.size, "one open-PR list, asked only when a branch on origin was about to go"
  end

  test "the tick treats merged as delivered in a repo without a Deploy workflow, and waits when it cannot tell" do
    it, status = delivered
    cache(status, nil)

    assert_empty cleaner.tick, "no repo summary yet: unknown, so wait"
    assert File.exist?(tree(it.n))

    workflow(nil)
    assert_equal 1, cleaner.tick.size
    assert_not File.exist?(tree(it.n))
  end

  test "the tick retries a skipped item later, saying the reason once, and still knows the PR after the cache forgot it" do
    it, status = delivered
    workflow("Deploy")
    cache(status, "live")
    File.write(File.join(tree(it.n), "notes.txt"), "not committed")

    assert_equal 1, cleaner.tick.size
    assert_match(/left worktree .*: it has uncommitted or untracked changes/, notes(it.n).first)
    assert_empty cleaner.tick, "not again within the retry interval"

    @redis.del(WorkQueue::StatusCache.pr_key(status.url), WorkQueue::StatusCache.delivery_key(status.url))
    assert_equal 1, cleaner.tick(now: 31.minutes.from_now).size
    assert_equal 1, notes(it.n).size, "the same reason is not logged twice"

    File.delete(File.join(tree(it.n), "notes.txt"))
    assert_equal 1, cleaner.tick(now: 62.minutes.from_now).size
    assert_not File.exist?(tree(it.n))
    assert_not local?(it.branch)
    assert_equal 2, notes(it.n).size
  end

  test "the tick leaves what was merged before it first ran, and unmerged pull requests" do
    old, old_status = delivered
    old_status.merged_at = 2.hours.ago.iso8601
    open = item(branch: "wq/7-open")
    sha = work(open.n, open.branch)
    workflow("Deploy")
    cache(old_status, "live")
    cache(pr(open, sha, state: "OPEN"), nil)

    assert_empty cleaner.tick
    assert File.exist?(tree(old.n))
    assert File.exist?(tree(open.n))
    assert remote?(old.branch)
    assert_empty notes(old.n)
  end

  test "tasks that share one branch and pull request count it, and remove it, once" do
    it, status = delivered
    twin = item(branch: it.branch, pr: it.n)
    workflow("Deploy")
    cache(status, "live")
    out = StringIO.new

    cleaner.sweep(dry_run: true, out: out)
    assert_match(/would remove: 1 worktrees, 1 local branches, 1 origin branches/, out.string)

    rows = cleaner.sweep(dry_run: false, out: StringIO.new)
    assert_equal 3, rows.values.flatten.sum { |r| r.removed.size }
    assert(rows.values.flatten.all?(&:complete?))
    assert_not remote?(it.branch)
    assert_equal 1, notes(it.n).size + notes(twin.n).size
  end

  test "the sweep's dry run removes nothing and reports what it would do" do
    it, status = delivered
    dirty, dirty_status = delivered
    File.write(File.join(tree(dirty.n), "notes.txt"), "not committed")
    workflow("Deploy")
    [status, dirty_status].each { |s| cache(s, "live") }
    out = StringIO.new

    cleaner.sweep(dry_run: true, out: out)

    assert File.exist?(tree(it.n))
    assert local?(it.branch)
    assert remote?(it.branch)
    assert_empty notes(it.n)
    assert_match(/DRY RUN/, out.string)
    assert_match(/would remove: 1 worktrees, 1 local branches, 2 origin branches/, out.string)
    assert_match(/left 1 - worktree: it has uncommitted or untracked changes/, out.string)

    cleaner.sweep(dry_run: false, out: StringIO.new)
    assert_not File.exist?(tree(it.n))
    assert File.exist?(tree(dirty.n))
    assert_equal 1, notes(it.n).size
    out = StringIO.new
    cleaner.sweep(dry_run: true, out: out)
    assert_no_match(/#{Regexp.escape(it.branch)}/, out.string)
  end
end
