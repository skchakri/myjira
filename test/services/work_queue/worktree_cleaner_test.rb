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
    @merged_prs = []
    @busy = {}
    @alive = {}
    @foreign = {}
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
      next [@open_prs.to_json, true] unless args.include?("merged")

      [@merged_prs.select { |p| p["headRefName"] == args[args.index("--head") + 1] }.to_json, true]
    end
    WorkQueue::WorktreeCleaner.new(store: @store, writer: @writer, logger: Logger.new(File::NULL), repo_for: ->(_) { @repo },
                                   gh: gh, busy: ->(path) { @busy[path] }, alive: ->(pid, _start) { @alive.fetch(pid, false) },
                                   foreign: ->(path) { @foreign[path] })
  end

  def agent_tree(id) = File.join(@repo, ".claude", "worktrees", "agent-#{id}")

  # What an isolated Claude agent leaves: a worktree under .claude/worktrees on its own branch.
  # Returns the head SHA (one commit past main unless commits: false).
  def agent(id, branch: "worktree-agent-#{id}", commits: true, push: false)
    sh(@repo, "git", "worktree", "add", "-q", "-b", branch, agent_tree(id), "main")
    sha = commits ? commit(agent_tree(id), "agent-#{id}.txt", "work") : sh(@repo, "git", "rev-parse", "main")
    sh(agent_tree(id), "git", "push", "-q", "origin", branch) if push
    sha
  end

  def merged_pr(branch, sha, number: 70)
    @merged_prs << { "number" => number, "url" => pr_url(number), "baseRefName" => "main", "headRefName" => branch,
                     "headRefOid" => sha, "mergeCommit" => nil, "mergedAt" => 1.hour.ago.iso8601 }
  end

  def orphan_steps(clean) = clean.orphan_results.values.flat_map(&:steps)

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

  # --- leftovers that belong to no task ------------------------------------------------

  test "the sweep removes an agent worktree and its branches once a merged pull request holds every commit" do
    item(branch: "wq/1-anchor", status: "queued") # the queue knows the repo
    sha = agent("a1", push: true)
    merged_pr("worktree-agent-a1", sha)
    out = StringIO.new

    cleaner.sweep(dry_run: true, out: out)
    assert File.exist?(agent_tree("a1"))
    assert local?("worktree-agent-a1")
    assert remote?("worktree-agent-a1")
    assert_match(/leftovers that belong to no task/, out.string)
    assert_match(/would remove: 1 worktrees, 1 local branches, 1 origin branches/, out.string)

    clean = cleaner
    clean.sweep(dry_run: false, out: StringIO.new)
    assert_equal %i[worktree local remote], orphan_steps(clean).select(&:removed?).map(&:kind)
    assert_not File.exist?(agent_tree("a1"))
    assert_not local?("worktree-agent-a1")
    assert_not remote?("worktree-agent-a1")
    assert local?("main")
    assert remote?("main")
  end

  test "an orphan branch that is already on origin's default branch goes without asking GitHub" do
    item(branch: "wq/1-anchor", status: "queued")
    sh(@repo, "git", "branch", "worktree-agent-b1", "main")

    clean = cleaner
    clean.sweep(dry_run: false, out: StringIO.new)

    assert_not local?("worktree-agent-b1")
    assert_empty @gh_calls
    assert_equal [[:local, "worktree-agent-b1"]], orphan_steps(clean).map { |s| [s.kind, s.target] }
  end

  test "an orphan branch with commits no merged pull request contains is left, with its worktree, and the reason is said" do
    item(branch: "wq/1-anchor", status: "queued")
    agent("c1")
    sha = agent("c2", push: true)
    merged_pr("worktree-agent-c2", sha)
    commit(agent_tree("c2"), "more.txt", "after the merge")
    sh(@repo, "git", "branch", "worktree-agent-c3", "worktree-agent-c1")
    out = StringIO.new

    clean = cleaner
    clean.sweep(dry_run: false, out: out, verbose: true)

    assert File.exist?(agent_tree("c1"))
    assert File.exist?(agent_tree("c2"))
    assert local?("worktree-agent-c1")
    assert local?("worktree-agent-c3")
    assert remote?("worktree-agent-c2"), "origin's copy is what was merged, but the local one moved on: both worktree and local stay"
    reasons = orphan_steps(clean).select(&:skipped?).to_h { |s| [[s.kind, File.basename(s.target)], s.reason] }
    assert_equal WorkQueue::WorktreeCleaner::Orphans::UNPROVEN, reasons[[:worktree, "agent-c1"]]
    assert_equal WorkQueue::WorktreeCleaner::Orphans::UNPROVEN, reasons[[:local, "worktree-agent-c3"]]
    assert_equal "it has commits its merged pull request never contained", reasons[[:worktree, "agent-c2"]]
    assert_match(/left, it has commits that are neither on origin's default branch nor in a merged pull request/, out.string)
  end

  test "an orphan's branch on origin is never deleted while a pull request is open on it" do
    item(branch: "wq/1-anchor", status: "queued")
    sha = agent("d1", push: true)
    merged_pr("worktree-agent-d1", sha)
    @open_prs = [{ "number" => 71, "headRefName" => "worktree-agent-d1", "baseRefName" => "main" }]

    clean = cleaner
    clean.sweep(dry_run: false, out: StringIO.new)

    assert remote?("worktree-agent-d1")
    assert_not local?("worktree-agent-d1")
    assert_equal ["pull request #71 is still open on it"], orphan_steps(clean).select(&:skipped?).map(&:reason)
  end

  test "an agent worktree on a branch a task still uses is none of the orphan sweep's business" do
    it = item(branch: "wq/2-in-agent-tree", status: "running")
    agent("e1", branch: it.branch, commits: false)

    clean = cleaner
    clean.sweep(dry_run: false, out: StringIO.new)

    assert File.exist?(agent_tree("e1"))
    assert local?(it.branch)
    assert_empty orphan_steps(clean)
  end

  test "a dirty or in-use agent worktree is left, and the default branch and main checkout are never candidates" do
    item(branch: "wq/1-anchor", status: "queued")
    agent("f1", commits: false)
    agent("f2", commits: false)
    File.write(File.join(agent_tree("f1"), "notes.txt"), "not committed")
    @busy[agent_tree("f2")] = 77

    clean = cleaner
    clean.sweep(dry_run: false, out: StringIO.new)

    assert File.exist?(agent_tree("f1"))
    assert File.exist?(agent_tree("f2"))
    assert local?("worktree-agent-f1")
    assert local?("main")
    assert File.exist?(File.join(@repo, "README"))
    assert_equal ["a session or process is still running in it", "it has uncommitted or untracked changes"],
                 orphan_steps(clean).map(&:reason).sort
  end

  test "a stale bundle worktree goes; one whose task is still open stays" do
    open = item(branch: "wq/1-anchor", status: "queued")
    stale = "#{@repo}-bundle-99"
    live = "#{@repo}-bundle-#{open.n}"
    [stale, live].each { |path| sh(@repo, "git", "worktree", "add", "-q", "--detach", path, "main") }

    cleaner.sweep(dry_run: false, out: StringIO.new)

    assert_not File.exist?(stale)
    assert File.exist?(live)
  end

  test "a leftover directory git no longer knows as a worktree is reported, never deleted" do
    item(branch: "wq/1-anchor", status: "queued")
    FileUtils.mkdir_p(File.join(agent_tree("g1"), "app"))
    FileUtils.mkdir_p(agent_tree("g2"))
    @foreign[agent_tree("g2")] = File.join(agent_tree("g2"), "log/test.log")

    clean = cleaner
    clean.sweep(dry_run: false, out: StringIO.new)

    assert File.exist?(File.join(agent_tree("g1"), "app"))
    steps = orphan_steps(clean).to_h { |s| [File.basename(s.target), s] }
    assert_match(/git no longer knows it as a worktree/, steps["agent-g1"].reason)
    assert_equal "files owned by another user; remove with sudo", steps["agent-g2"].reason
    assert_equal "log/test.log", steps["agent-g2"].detail
  end

  # --- locks and other users' files ----------------------------------------------------

  test "a worktree locked by an agent that has ended is unlocked and cleaned; a live agent's lock is kept" do
    item(branch: "wq/1-anchor", status: "queued")
    agent("h1", commits: false)
    agent("h2", commits: false)
    sh(@repo, "git", "worktree", "lock", "--reason", "claude agent agent-h1 (pid 4001 start 123)", agent_tree("h1"))
    sh(@repo, "git", "worktree", "lock", "--reason", "claude agent agent-h2 (pid 4002 start 456)", agent_tree("h2"))
    @alive[4002] = true

    clean = cleaner
    clean.sweep(dry_run: true, out: StringIO.new)
    assert_match(/locked/, sh(@repo, "git", "worktree", "list", "--porcelain").split("\n\n").find { |b| b.include?("agent-h1") },
                 "a dry run does not release the lock")

    clean.sweep(dry_run: false, out: StringIO.new)

    assert_not File.exist?(agent_tree("h1"))
    assert_not local?("worktree-agent-h1")
    assert File.exist?(agent_tree("h2"))
    assert local?("worktree-agent-h2")
    steps = orphan_steps(clean)
    assert_equal "the lock of an agent that has ended was released", steps.find { |s| s.removed? && s.kind == :worktree }.detail
    kept = steps.find { |s| s.skipped? && s.kind == :worktree }
    assert_equal ["it is locked by an agent that is still running", "pid 4002"], [kept.reason, kept.detail]
  end

  test "a lock with an unknown reason, or none, is always kept, and a dead agent's lock does not excuse a dirty worktree" do
    it, status = delivered
    sh(@repo, "git", "worktree", "lock", "--reason", "on a usb stick", tree(it.n))
    result = cleaner.clean(it, status)
    assert File.exist?(tree(it.n))
    assert_equal ["it is locked", "on a usb stick"], [result.skipped.first.reason, result.skipped.first.detail]

    sh(@repo, "git", "worktree", "unlock", tree(it.n))
    sh(@repo, "git", "worktree", "lock", tree(it.n))
    assert_equal "it is locked", cleaner.clean(it, status).skipped.first.reason

    sh(@repo, "git", "worktree", "unlock", tree(it.n))
    sh(@repo, "git", "worktree", "lock", "--reason", "claude agent agent-x (pid 4003 start 9)", tree(it.n))
    File.write(File.join(tree(it.n), "notes.txt"), "not committed")
    result = cleaner.clean(it, status)
    assert_equal "it has uncommitted or untracked changes", result.skipped.first.reason
    assert_match(/locked/, sh(@repo, "git", "worktree", "list", "--porcelain"), "nothing was removed, so the lock stays")
  end

  test "the real liveness check knows this process, a reused pid and a pid that is gone" do
    start = File.read("/proc/#{Process.pid}/stat").then { |s| s[(s.rindex(")") + 2)..].split[19] }
    assert WorkQueue::WorktreeCleaner.process_alive?(Process.pid, start)
    assert WorkQueue::WorktreeCleaner.process_alive?(Process.pid)
    assert_not WorkQueue::WorktreeCleaner.process_alive?(Process.pid, start.to_i + 1), "same pid, another process"
    pid = spawn("true")
    Process.wait(pid)
    assert_not WorkQueue::WorktreeCleaner.process_alive?(pid)
  end

  test "a worktree with files of another user is not attempted and says to use sudo" do
    it, status = delivered
    @foreign[tree(it.n)] = File.join(tree(it.n), "log/development.log")

    result = cleaner.clean(it, status)

    assert File.exist?(tree(it.n))
    assert_equal ["files owned by another user; remove with sudo", "log/development.log"], [result.skipped.first.reason, result.skipped.first.detail]
    assert_match(/files owned by another user; remove with sudo/, result.note)
    assert_nil WorkQueue::WorktreeCleaner.foreign_file(tree(it.n)), "the real check: everything here is ours"
    assert_equal ["files owned by another user; remove with sudo"],
                 cleaner.send(:removal_failure, "error: failed to delete '/x/log': Permission denied")
  end

  # --- what the task detail and the Releases page read -----------------------------------

  test "the outcome of a cleanup is kept for the task detail and the Releases page" do
    it, status = delivered
    dirty, dirty_status = delivered
    File.write(File.join(tree(dirty.n), "notes.txt"), "not committed")
    waiting = item(branch: "wq/9-waiting")
    workflow("Deploy")
    [status, dirty_status].each { |s| cache(s, "live") }
    cache(pr(waiting, "abc"), "not_live")

    cleaner.tick

    cleaned = WorkQueue::CleanupReport.for(it)
    assert_equal ["cleaned", 3, 0], [cleaned.state, cleaned.removed.size, cleaned.skipped.size]
    left = WorkQueue::CleanupReport.for(dirty)
    assert_equal "left", left.state
    assert_equal ["it has uncommitted or untracked changes", "it is still checked out in a worktree"], left.skipped.map(&:reason)
    assert_equal ["origin branch #{dirty.branch}"], left.removed.map(&:to_s)
    assert_equal ["waiting", "merged but not deployed yet (not live)"], WorkQueue::CleanupReport.for(waiting).then { |t| [t.state, t.reason] }
    assert_nil WorkQueue::CleanupReport.for(item(branch: "wq/10-open", status: "running"))
    assert_equal [dirty.n], WorkQueue::CleanupReport.left(@store.all).map { |l| l.item.n }

    File.delete(File.join(tree(dirty.n), "notes.txt"))
    cleaner.tick(now: 31.minutes.from_now)
    again = WorkQueue::CleanupReport.for(dirty)
    assert_equal ["cleaned", 3], [again.state, again.removed.size], "what the first attempt removed is still listed"
  end

  test "the sweep keeps what it found that belongs to no task, per repo, and forgets it once nothing is left" do
    item(branch: "wq/1-anchor", status: "queued")
    agent("k1")

    cleaner.sweep(dry_run: true, out: StringIO.new)

    report = WorkQueue::CleanupReport.orphans.sole
    assert_equal [@repo, "me/app", [SLUG], true], [report.repo, report.name, report.slugs, report.dry_run]
    assert_equal ["worktree"], report.skipped.map(&:label)
    assert_empty WorkQueue::CleanupReport.orphans(slug: "another-project")

    sh(@repo, "git", "worktree", "remove", "--force", agent_tree("k1"))
    sh(@repo, "git", "branch", "-D", "worktree-agent-k1")
    FileUtils.rm_rf(File.join(@repo, ".claude"))
    cleaner.sweep(dry_run: true, out: StringIO.new)
    assert_empty WorkQueue::CleanupReport.orphans
  end
end
