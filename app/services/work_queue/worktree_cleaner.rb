require "open3"

module WorkQueue
  # Tidies up after a delivered item: once its PR is merged AND deployed, removes
  # the item's git worktree, its local branch and its branch on origin.
  #
  # "Deployed" (see #waiting):
  #   * the repo has a Deploy workflow  -> Delivery says "live" for the PR
  #   * the repo has no Deploy workflow -> merged is enough (nothing else to wait for)
  #   * anything unknown                -> wait
  # A follow-up that shipped in its parent's bundle PR carries that PR, so it is
  # cleaned when the bundle PR is merged and deployed.
  #
  # The supervisor (bin/work-queue-runner) calls #tick every few minutes. The tick
  # asks GitHub nothing about delivery: it reads the PR and delivery state the
  # watcher already keeps in Redis (StatusCache). Its only GitHub call is one
  # "open PRs of this repo" list, made right before a branch is deleted on origin.
  # It runs in the runner rather than the watcher because the runner is on the host:
  # it can see the processes working in a worktree and has the git push credentials.
  #
  # These are deletions, so every check errs towards leaving things alone:
  #   * never the main checkout, the default branch, main/master, the PR's base
  #     branch, or whatever the main checkout has checked out;
  #   * only branches named by the item (its branch, its PR's head branch, its bundle
  #     branch), and only while no open item uses the same branch or PR;
  #   * PRs are squash-merged, so ancestry on main proves nothing. A branch goes only
  #     when its tip is the PR's head commit, or is contained in it (or in origin's
  #     default branch); a tip with commits the PR never had is left alone;
  #   * a worktree goes only when it is clean (ignored files excepted), unlocked and
  #     no process has its working directory inside it; `git worktree remove` runs
  #     without --force;
  #   * a branch on origin goes only when no open PR uses it as head or base, and the
  #     delete is conditional on the commit that was checked (--force-with-lease).
  # Anything skipped is said on the item's log with the reason, and tried again later.
  class WorktreeCleaner
    Step = Struct.new(:kind, :target, :outcome, :reason, :detail, keyword_init: true) do
      def removed? = outcome == :removed
      def skipped? = outcome == :skipped
    end

    # waiting: not merged and deployed yet. ignored: not ours to clean, ever (said in the
    # sweep's report, never on the item).
    Result = Struct.new(:item, :waiting, :ignored, :steps, :dry_run, keyword_init: true) do
      def removed = steps.select(&:removed?)
      def skipped = steps.select(&:skipped?)
      # Nothing is left to try again.
      def complete? = waiting.nil? && skipped.empty?

      def note
        verb = dry_run ? "would remove" : "removed"
        parts = []
        parts << "#{verb} #{removed.map { |s| "#{WorktreeCleaner::LABEL[s.kind]} #{s.target}#{" (#{s.detail})" if s.detail}" }.join(', ')}" if removed.any?
        parts << "left #{skipped.map { |s| "#{WorktreeCleaner::LABEL[s.kind]} #{s.target}: #{s.reason}#{" (#{s.detail})" if s.detail}" }.join('; ')}" if skipped.any?
        parts.any? ? "Cleanup after deploy: #{parts.join('. ')}" : nil
      end
    end

    Worktree = Struct.new(:path, :head, :branch, :locked, :main, keyword_init: true)

    LABEL = { worktree: "worktree", local: "local branch", remote: "origin branch" }.freeze
    NOT_DEPLOYED = %w[not_live deploying deploy_failed testing stacked ci_failed].freeze
    BRANCH = %r{\A[A-Za-z0-9_][A-Za-z0-9_./-]*\z}
    ALWAYS_KEPT = %w[main master HEAD].freeze
    TICK_EVERY = 5.minutes
    RETRY_EVERY = 30.minutes
    MARK_TTL = 90.days.to_i
    PR_FACTS = %i[url number state base head head_sha merge_sha merged_at].freeze
    # A daemon has nobody to answer a credential prompt.
    NET_ENV = { "GIT_TERMINAL_PROMPT" => "0",
                "GIT_SSH_COMMAND" => ENV.fetch("GIT_SSH_COMMAND", "ssh -o BatchMode=yes -o ConnectTimeout=15") }.freeze

    def self.enabled? = ENV.fetch("WORK_QUEUE_CLEANUP", "1") != "0"
    def self.mark_key(item_key) = "#{RunState::PREFIX}:cleanup:#{item_key}"

    # The tick only cleans up after PRs merged from the moment it first ran; everything
    # delivered before that is left for the sweep (`rails work_queue:cleanup_worktrees`),
    # which the person runs by hand after reading its dry run.
    def self.since
      key = "#{RunState::PREFIX}:cleanup_since"
      RunState.redis.set(key, Time.current.to_f, nx: true)
      Time.zone.at(RunState.redis.get(key).to_f)
    end

    # The first process (pid) whose working directory is inside `path`, or nil.
    def self.process_in(path)
      root = File.realpath(path)
      Dir.glob("/proc/[0-9]*/cwd").each do |link|
        cwd = File.readlink(link)
        return link.split("/")[2].to_i if cwd == root || cwd.start_with?("#{root}/")
      rescue SystemCallError
        next # another user's process, or one that just ended
      end
      nil
    rescue SystemCallError
      nil
    end

    # gh: ->(*args) { [stdout, ok] }; busy: ->(path) { pid or nil }; repo_for: ->(slug) { path }
    def initialize(store: Store.new, writer: QueueWriter.new, logger: Rails.logger, repo_for: nil, gh: nil, busy: nil)
      @store = store
      @writer = writer
      @logger = logger
      @repo_for = repo_for || Workspace.method(:repo_for)
      @gh = gh || method(:run_gh)
      @busy = busy || self.class.method(:process_in)
      @open_prs = {}
    end

    # Called by the supervisor. Cleans up after every item whose PR was merged since the
    # tick first ran and is now deployed; an item with something left is tried again later.
    def tick(now: Time.current)
      return [] unless self.class.enabled?

      since = self.class.since
      @open_prs = {}
      @states = nil
      @handled = Set.new
      open = nil
      candidates = @store.all.select { |i| i.status == "done" && i.pr.present? && i.updated_at.present? && i.updated_at >= since }
      candidates.filter_map do |item|
        mark = redis.hgetall(self.class.mark_key(item.key))
        next if mark["done"].present? || (mark["tried_at"].present? && Time.zone.at(mark["tried_at"].to_f) > now - RETRY_EVERY)

        pr = remembered(mark) || confirm(item, since)
        next unless pr

        result = clean(item, pr, open: (open ||= @store.all.select(&:open?)))
        record(item, result, mark, now)
        result
      rescue StandardError => e
        @logger.error("[work-queue] cleanup #{item.key} failed: #{e.class}: #{e.message}")
        nil
      end
    end

    # Why this item is not ready to be cleaned up yet (nil = merged and deployed).
    # `summary` is the repo's Delivery.summary (nil = the watcher has not looked yet).
    def waiting(pr, delivery, summary)
      return "its pull request has not been looked up yet" if pr.nil? || pr.repo.blank?
      return "its pull request is not merged" unless pr.merged?
      return nil if delivery&.live?
      return "merged but not deployed yet (#{delivery.state.tr('_', ' ')})" if NOT_DEPLOYED.include?(delivery&.state)
      return "its deploy state is not known yet" if summary.nil? || summary.workflow?

      nil # no Deploy workflow in this repo: merged is all there is
    end

    # One item whose PR is known to be merged and deployed. Never raises for a git or
    # GitHub failure: that becomes a skipped step.
    def clean(item, pr, dry_run: false, open: nil)
      result = Result.new(item: item, steps: [], dry_run: dry_run)
      return result unless pr&.merged? # belt and braces: nothing is ever removed for an unmerged PR

      names = branches_of(item, pr)
      return result if names.empty?

      repo = main_checkout(item)
      return ignore(result, "its repo is not on this machine") unless repo
      return ignore(result, "its pull request is in another repo (#{pr.repo})") unless origin?(repo, pr.repo)

      user = (open || @store.all.select(&:open?)).find { |o| o.key != item.key && same_work?(o, item, names, repo) }
      return skip(result, :local, names.first, "task ##{user.n} is still open on the same branch or pull request") if user

      trees = worktrees(repo)
      kept = kept_branches(repo, trees, pr)
      # What this run already removed (or, in a dry run, would have): tasks that share a
      # branch must not count it, or try it, twice.
      @handled ||= Set.new
      gone = @handled.filter_map { |r, kind, path| path if r == repo && kind == :worktree }
      names.each do |name|
        next skip(result, :local, name, "a protected branch, never removed") if kept.include?(name)

        clean_branch(result, repo, name, pr, trees, gone)
      end
      git(repo, "worktree", "prune") if gone.any? && !dry_run
      result
    end

    # Leftovers from items delivered before the tick existed (or that it gave up on):
    # every done item with a PR, any age. Unlike the tick this may ask GitHub, but only
    # for the items that still have something on disk or on origin.
    #   WorkQueue::WorktreeCleaner.new.sweep                  # dry run: report only
    #   WorkQueue::WorktreeCleaner.new.sweep(dry_run: false)  # remove, and log on each item
    def sweep(dry_run: true, out: $stdout, verbose: false, prs: PullRequests.new, delivery: Delivery.new)
      @open_prs = {}
      @states = {}
      @handled = Set.new
      open = @store.all.select(&:open?)
      looked = {}
      rows = Hash.new { |h, k| h[k] = [] }
      @store.all.select { |i| i.status == "done" && i.pr.present? }.sort_by { |i| [i.slug, i.n] }.each do |item|
        repo = main_checkout(item) or next
        named = branches_of(item, nil)
        next if named.any? && !leftovers?(repo, named)

        look = looked[item.pr] ||= { pr: merged_pr(item.pr, prs) }
        pr = look[:pr]
        # A task that names no branch: only its pull request knows which one it was.
        next if named.empty? && (pr.nil? || !leftovers?(repo, branches_of(item, pr)))

        state = look.fetch(:state) { look[:state] = deploy_state(item.pr, pr, delivery) }
        wait = state.is_a?(String) ? state : waiting(pr, state, pr&.repo.presence && Delivery.summary(pr.repo))
        result = wait ? Result.new(item: item, waiting: wait, steps: [], dry_run: dry_run) : clean(item, pr, dry_run: dry_run, open: open)
        record(item, result, redis.hgetall(self.class.mark_key(item.key)), Time.current) unless dry_run || wait
        rows[repo] << result
      rescue StandardError => e
        @logger.error("[work-queue] cleanup sweep #{item.key} failed: #{e.class}: #{e.message}")
      end
      report(rows, dry_run, out, verbose)
      rows
    end

    private

    def redis = RunState.redis

    # --- when is an item ready ------------------------------------------------

    # The PR facts stored when the item was first seen merged and deployed. StatusCache
    # forgets a live PR after a day; a retry (say, the worktree was dirty) must not.
    def remembered(mark)
      return if mark["pr"].blank?

      PullRequests::Status.new(**JSON.parse(mark["pr"]).symbolize_keys.slice(*PR_FACTS))
    rescue JSON::ParserError
      nil
    end

    # Merged and deployed, going by what the watcher cached. Stores the PR facts when so.
    def confirm(item, since)
      pr = StatusCache.pr(item.pr)
      return if waiting(pr, StatusCache.delivery(item.pr), pr&.repo.presence && Delivery.summary(pr.repo))

      merged_at = pr.merged_at.presence && Time.zone.parse(pr.merged_at.to_s)
      if merged_at.nil? || merged_at < since
        # Delivered before the tick existed: the sweep's business, never looked at again here.
        redis.hset(self.class.mark_key(item.key), "done", "before")
        redis.expire(self.class.mark_key(item.key), MARK_TTL)
        return
      end
      redis.hset(self.class.mark_key(item.key), "pr", pr.to_h.slice(*PR_FACTS).to_json)
      pr
    rescue ArgumentError
      nil
    end

    # For the sweep: the PR from the cache, else from GitHub (a cached "not merged" may be old).
    def merged_pr(ref, prs)
      pr = StatusCache.pr(ref)
      pr&.merged? ? pr : prs.fetch(ref)
    end

    # For the sweep: the delivery state from the cache, else from GitHub. A String is the
    # reason it could not be found out.
    def deploy_state(ref, pr, delivery)
      return unless pr&.merged?

      StatusCache.delivery(ref) || delivery.compute(pr)
    rescue Delivery::Unavailable => e
      "GitHub could not be asked about its deploy (#{e.message.truncate(80)})"
    end

    # --- what belongs to an item ------------------------------------------------

    # The item's own branch, its PR's head branch and its bundle's branch.
    def branches_of(item, pr)
      [item.branch, pr&.head, item.bundle_info["branch"]].filter_map { |b| b.to_s.strip.presence }.uniq.select { |b| b.match?(BRANCH) && !b.include?("..") }
    end

    def same_work?(other, item, names, repo)
      return true if other.pr.present? && other.pr == item.pr

      names.include?(other.branch.to_s.strip) && main_checkout(other) == repo
    end

    # The repo's main checkout (its queue may be filed under one of its worktrees).
    def main_checkout(item)
      path = item.repo.presence || @repo_for.call(item.slug)
      return if path.blank? || !File.directory?(path)

      (@mains ||= {})[path] ||= worktrees(path).find(&:main)&.path
    end

    def origin?(repo, name)
      url, ok = git(repo, "remote", "get-url", "origin")
      ok && url.sub(/\.git\z/, "").downcase.end_with?("/#{name.downcase}", ":#{name.downcase}")
    end

    def worktrees(repo)
      out, ok = git(repo, "worktree", "list", "--porcelain")
      return [] unless ok

      out.split(/\n\n+/).each_with_index.filter_map do |block, i|
        lines = block.lines.map(&:chomp)
        path = lines.find { |l| l.start_with?("worktree ") }&.delete_prefix("worktree ") or next
        Worktree.new(path: path, main: i.zero?, head: lines.find { |l| l.start_with?("HEAD ") }&.delete_prefix("HEAD "),
                     branch: lines.find { |l| l.start_with?("branch refs/heads/") }&.delete_prefix("branch refs/heads/"),
                     locked: lines.any? { |l| l == "locked" || l.start_with?("locked ") })
      end
    end

    def default_branch(repo)
      ref, ok = git(repo, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD")
      return ref.delete_prefix("origin/") if ok && ref.present?

      %w[main master].find { |b| git?(repo, "rev-parse", "--verify", "-q", "refs/heads/#{b}") } || "main"
    end

    def kept_branches(repo, trees, pr)
      (ALWAYS_KEPT + [default_branch(repo), pr.base, trees.find(&:main)&.branch]).compact.uniq
    end

    # Is there anything of this item's left to look at? Local reads plus one
    # `git ls-remote` per repo, so the sweep asks GitHub only about real leftovers.
    def leftovers?(repo, names)
      state = (@states ||= {})[repo] ||= begin
        locals = git(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads").first.split("\n")
        out, ok = git(repo, "ls-remote", "--heads", "origin", net: true)
        { local: locals, remote: ok ? out.lines.to_h { |l| l.strip.split("\t").then { |sha, ref| [ref.to_s.delete_prefix("refs/heads/"), sha] } } : nil }
      end
      state[:remote].nil? || names.intersect?(state[:local]) || names.intersect?(state[:remote].keys)
    end

    # The branch's commit on origin: "" when origin has no such branch, nil when origin could
    # not be reached. The sweep listed origin's branches once already; the tick asks per branch.
    # (A stale answer cannot delete anything it should not: the delete is tied to this commit.)
    def remote_sha(repo, name)
      listed = @states&.dig(repo, :remote)
      return listed[name].to_s if listed

      out, ok = git(repo, "ls-remote", "origin", "refs/heads/#{name}", net: true)
      ok ? out.split.first.to_s : nil
    end

    # --- the removals -----------------------------------------------------------

    def clean_branch(result, repo, name, pr, trees, gone)
      local = git(repo, "rev-parse", "--verify", "-q", "refs/heads/#{name}").then { |sha, ok| ok ? sha : nil }
      local = nil if @handled.include?([repo, :local, name])
      mine = trees.select { |t| t.branch == name && !gone.include?(t.path) }
      if local && !contained?(repo, local, pr)
        why = "it has commits the merged pull request never contained"
        mine.each { |t| skip(result, :worktree, t.path, why, "#{name} at #{local[0, 7]}, PR head #{pr.head_sha.to_s[0, 7]}") }
        skip(result, :local, name, why, "at #{local[0, 7]}, PR head #{pr.head_sha.to_s[0, 7]}")
      else
        mine.each { |t| remove_worktree(result, repo, t, gone) }
        delete_local(result, repo, name, local, trees, gone) if local
      end
      delete_remote(result, repo, name, pr)
    end

    # Every commit of `sha` shipped: it is the PR's head (or its merge commit), or an
    # ancestor of one of them or of origin's default branch.
    def contained?(repo, sha, pr)
      return true if [pr.head_sha, pr.merge_sha].compact.include?(sha)
      return false unless object?(repo, sha)

      [pr.head_sha, pr.merge_sha, "refs/remotes/origin/#{default_branch(repo)}"].compact.any? do |tip|
        object?(repo, tip) && git?(repo, "merge-base", "--is-ancestor", sha, tip)
      end
    end

    def object?(repo, rev) = git?(repo, "cat-file", "-e", "#{rev}^{commit}")

    def remove_worktree(result, repo, tree, gone)
      why, detail = worktree_blocker(repo, tree)
      return skip(result, :worktree, tree.path, why, detail) if why

      unless result.dry_run
        _, ok, err = git(repo, "worktree", "remove", tree.path)
        return skip(result, :worktree, tree.path, "git would not remove it", err.lines.last.to_s.strip.truncate(140)) unless ok
      end
      gone << tree.path
      @handled << [repo, :worktree, tree.path]
      done(result, :worktree, tree.path)
    end

    def worktree_blocker(repo, tree)
      return ["it is the main checkout"] if tree.main || same_dir?(tree.path, repo)
      return nil unless File.directory?(tree.path) # already gone from disk: `worktree prune` drops the entry
      return ["it is locked"] if tree.locked

      status, ok = git(tree.path, "status", "--porcelain", "--untracked-files=normal")
      return ["its state could not be read"] unless ok
      return ["it has uncommitted or untracked changes", "#{status.lines.size} #{'path'.pluralize(status.lines.size)}"] if status.present?

      pid = @busy.call(tree.path)
      return ["a session or process is still running in it", "pid #{pid}"] if pid

      nil
    end

    def same_dir?(a, b)
      File.realpath(a) == File.realpath(b)
    rescue SystemCallError
      a.to_s.chomp("/") == b.to_s.chomp("/")
    end

    def delete_local(result, repo, name, sha, trees, gone)
      holder = trees.find { |t| t.branch == name && !gone.include?(t.path) }
      return skip(result, :local, name, "it is still checked out in a worktree", holder.path) if holder

      unless result.dry_run
        _, ok, err = git(repo, "branch", "-D", name)
        return skip(result, :local, name, "git would not delete it", err.lines.last.to_s.strip.truncate(140)) unless ok
      end
      @handled << [repo, :local, name]
      done(result, :local, name, "was #{sha[0, 7]}")
    end

    def delete_remote(result, repo, name, pr)
      return if @handled.include?([repo, :remote, name])

      sha = remote_sha(repo, name)
      return skip(result, :remote, name, "origin could not be reached") if sha.nil?
      return if sha.blank? # already deleted (GitHub removes merged branches itself in some repos)
      return skip(result, :remote, name, "it has commits the merged pull request never contained", "at #{sha[0, 7]}") unless contained?(repo, sha, pr)

      open = open_prs(pr.repo)
      return skip(result, :remote, name, "GitHub could not be asked whether another pull request uses it") if open.nil?

      other = open.find { |p| [p["headRefName"], p["baseRefName"]].include?(name) }
      return skip(result, :remote, name, "pull request ##{other['number']} is still open on it") if other

      unless result.dry_run
        _, ok, err = git(repo, "push", "origin", "--force-with-lease=refs/heads/#{name}:#{sha}", ":refs/heads/#{name}", net: true)
        return if !ok && err.match?(/remote ref does not exist/i) # deleted between the two calls

        return skip(result, :remote, name, "the push to delete it failed", err.lines.last.to_s.strip.truncate(140)) unless ok
      end
      @handled << [repo, :remote, name]
      done(result, :remote, name, "was #{sha[0, 7]}")
    end

    # Open PRs of the repo (head + base branch), asked once per run and only when a branch
    # on origin is about to be deleted. nil = GitHub could not be asked.
    def open_prs(name)
      return @open_prs[name] if @open_prs.key?(name)
      return @open_prs[name] = nil if Delivery.paused_until

      out, ok = @gh.call("pr", "list", "-R", name, "--state", "open", "--limit", "500", "--json", "number,headRefName,baseRefName")
      @open_prs[name] = ok ? JSON.parse(out) : nil
    rescue JSON::ParserError
      @open_prs[name] = nil
    end

    def done(result, kind, target, detail = nil)
      result.steps << Step.new(kind: kind, target: target, outcome: :removed, detail: detail)
      result
    end

    def ignore(result, why)
      result.ignored = why
      result
    end

    def skip(result, kind, target, reason, detail = nil)
      result.steps << Step.new(kind: kind, target: target, outcome: :skipped, reason: reason, detail: detail)
      result
    end

    # --- bookkeeping --------------------------------------------------------------

    # One line on the item's log per distinct outcome (a skip that repeats is not said
    # twice), and the marker that makes the next tick a no-op.
    def record(item, result, mark, now)
      note = result.note
      left = result.skipped.map { |s| [s.kind, s.target, s.reason].join(" ") }.join("|")
      if note && (result.removed.any? || left != mark["last"])
        @writer.update(item.slug, item.n, log: note)
        Broadcaster.item_note(item, note)
      end
      key = self.class.mark_key(item.key)
      redis.hset(key, { "tried_at" => now.to_f.to_s, "last" => left }.merge(result.complete? ? { "done" => now.iso8601 } : {}))
      redis.expire(key, MARK_TTL)
    rescue ArgumentError, SystemCallError => e
      @logger.warn("[work-queue] cleanup #{item.key}: could not write the item log: #{e.message}")
    end

    def report(rows, dry_run, out, verbose)
      verb = dry_run ? "would remove" : "removed"
      out.puts(dry_run ? "DRY RUN: nothing was removed. Run with DRY_RUN=0 to remove." : "Removed:")
      rows.sort.each do |repo, results|
        steps = results.flat_map(&:steps)
        count = ->(kind) { steps.count { |s| s.removed? && s.kind == kind } }
        out.puts "\n#{repo}  (#{results.size} delivered #{'task'.pluralize(results.size)} with leftovers)"
        out.puts "  #{verb}: #{count.call(:worktree)} worktrees, #{count.call(:local)} local branches, #{count.call(:remote)} origin branches"
        reasons = steps.select(&:skipped?).map { |s| "#{LABEL[s.kind]}: #{s.reason}" } + results.filter_map { |r| (why = r.waiting || r.ignored) && "task: #{why}" }
        reasons.tally.sort_by { |why, n| [-n, why] }.each { |why, n| out.puts "  left #{n} - #{why}" }
        next unless verbose

        results.each { |r| out.puts "    ##{r.item.n} #{r.item.title.truncate(50)}: #{r.waiting || r.ignored || r.note || 'nothing to do'}" }
      end
      out.puts "\nNothing to clean up." if rows.empty?
    end

    # --- shelling out ---------------------------------------------------------------

    # => [stdout, ok, stderr]
    def git(dir, *args, net: false)
      out, err, status = Open3.capture3(net ? NET_ENV : {}, "git", "-c", "safe.directory=*", "-C", dir.to_s, *args)
      [out.strip, status.success?, err.strip]
    rescue SystemCallError => e
      ["", false, e.message]
    end

    # Did the command succeed? (git's tuple ends with stderr, so never ask it for `.last`.)
    def git?(dir, *args) = git(dir, *args)[1]

    def run_gh(*args)
      return ["", false] unless PullRequests.gh?

      out, status = Open3.capture2("gh", *args, err: File::NULL)
      [out, status.success?]
    rescue SystemCallError
      ["", false]
    end
  end
end
