require "open3"

module WorkQueue
  # Ships a bundle (a root item plus all its follow-up descendants) as ONE PR,
  # so CI runs once per bundle instead of once per item.
  #
  # Item agents only commit + push their own branch and get flagged
  # "readyToBundle". When every live member of a bundle is ready (dropped and
  # merged ones are ignored; running/queued/blocked/triage ones are waited on),
  # this merges each branch into bundle/<root>-<slug> off main, runs the
  # project's full suite + lint once, bisects out the members that break it,
  # pushes, opens one PR and links every shipped member to it (item["pr"]), so
  # the per-item CI/deploy tracking (StatusCache, Delivery) keeps working.
  #
  # A follow-up that finishes while its bundle's PR is still open is merged onto
  # that same bundle branch, so it lands in the parent's PR. Only when the
  # parent's PR is already merged/closed does it get a new bundle (and PR).
  #
  # A red run is only blamed on members when the base is green by itself. When
  # the base is red too (or the suite cannot run in the bundle worktree), nobody
  # is blocked: the items keep "readyToBundle" and get a log line with the reason.
  #
  # Repos that homey's release train batches (HomeyTrain.batched?) skip the local suite
  # and its bisect: homey runs CI on the bundle PR inside a batch/** branch, merges it when
  # green and names the culprit when red, so here the bundle is only merged and pushed.
  class Bundler
    WAIT = %w[triage queued running blocked].freeze
    IGNORE = %w[dropped merged].freeze
    Member = Struct.new(:item, :branch)
    # A base that was red is tried again when it moves, or after this long (the cause may be outside git).
    RECHECK_RED_BASE = 15.minutes
    TAIL_LINES = 8
    TAIL_CHARS = 600

    # shell: ->(cwd, *cmd) { [output, ok] }; resolver: ->(cwd, branch) { ok }
    # batched: ->(repo_path) { true when homey's release train tests this repo's PRs }
    def initialize(store: Store.new, writer: QueueWriter.new, logger: Rails.logger, shell: nil, resolver: nil, repo_for: nil, commands: nil,
                   batched: nil)
      @store = store
      @writer = writer
      @logger = logger
      @shell = shell || method(:sh)
      @resolver = resolver || method(:claude_resolve)
      @repo_for = repo_for || Workspace.method(:repo_for)
      @commands = commands || method(:detect_commands)
      @batched = batched || method(:homey_batched?)
      @red_bases = {}
    end

    def tick
      @store.projects.each do |slug, items|
        ready_bundles(items).each { |root, members, branch| ship(slug, root, members, branch) }
      end
    end

    # [[root item, member items in tree order, branch]] for bundles whose members are all ready.
    def ready_bundles(items)
      by_n = items.index_by(&:n)
      items.select { |i| candidate?(i) }.group_by { |i| root_of(i, by_n) }.filter_map do |root, _|
        members = tree(root, items).select { |i| member?(i) }
        next if members.empty? || members.any? { |i| WAIT.include?(i.status) || i.awaiting_approval || !i.ready_to_bundle? }

        [root, members, branch_for(root, items)]
      end
    end

    # "Ready for PR" in the detail pane: ship the members of this item's bundle
    # that are ready now, without waiting for the rest.
    def ship_now(key)
      item = @store.find(key) or return
      items = @store.items_for(item.slug)
      root = root_of(item, items.index_by(&:n))
      members = tree(root, items).select { |i| member?(i) && i.ready_to_bundle? }
      return @logger.info("[work-queue] #{key}: nothing ready to bundle") if members.empty?

      ship(item.slug, root, members, branch_for(root, items), force: true)
    end

    # Members whose repo differs from the root's can't share its PR: each ships
    # as its own one-item bundle (and PR) in its own repo. force: try even if the base was just seen red.
    def ship(slug, root, items, branch, force: false)
      root_repo = repo_of(root)
      own, foreign = items.partition { |i| repo_of(i) == root_repo }
      foreign.each { |i| ship_in(repo_of(i), slug, i, [i], solo_branch(i), onto: nil, force: force) }
      return if own.empty?

      onto = open_bundle(root, @store.items_for(slug)) == branch ? branch : nil
      ship_in(root_repo, slug, root, own, branch, onto: onto, force: force)
    end

    private

    def ship_in(repo, slug, root, items, branch, onto:, force: false)
      return @logger.warn("[work-queue] bundle #{slug}:#{root.n} waiting: no repo_path") unless repo

      path = "#{repo}-bundle-#{root.n}"
      members = items.map { |i| Member.new(i, i.branch) }
      base = setup(repo, path, onto: onto)
      sha = git(path, "rev-parse", "HEAD").first.to_s.strip
      seen = @red_bases[[slug, path]]
      seen = nil unless seen && seen[:sha] == sha
      return if seen && seen[:at] > RECHECK_RED_BASE.ago && !force

      log(slug, items, onto ? "Adding #{items.size} item(s) to the open bundle #{branch}" : "Bundling #{items.size} item(s) into #{branch}") unless seen
      merged, failed = merge_all(path, branch, base, members)
      return ship_to_homey(slug, root, path, branch, merged, failed, append: onto.present?) if @batched.call(repo)

      cmds = @commands.call(path)
      red = merged.any? ? failure(path, cmds) : nil
      if red && (base_red = base_failure(path, base, cmds))
        failed.each { |m, why| fail_member(slug, root, m, why) }
        return red_base(slug, path, base, sha, merged, base_red, seen)
      end
      @red_bases.delete([slug, path])

      bad = red ? isolate(path, branch, base, merged, cmds, red) : []
      failed += bad.map { |m, why| [m, "Breaks the bundle's test/lint run: #{why}"] }
      good = merged - bad.map(&:first)
      if bad.any? && good.any?
        rebuild(path, branch, base, good)
        if (still = failure(path, cmds))
          failed += good.map { |m| [m, "Bundle still red after removing the failing items: #{still}"] }
          good = []
        end
      end
      failed.each { |m, why| fail_member(slug, root, m, why) }
      publish(slug, root, path, branch, good, failed, append: onto.present?) if good.any?
    ensure
      cleanup(repo, path) if repo && path
    end

    # homey's release train is this repo's CI: no local suite or bisect, the bundle PR is its input.
    def ship_to_homey(slug, root, path, branch, merged, failed, append:)
      failed.each { |m, why| fail_member(slug, root, m, why) }
      publish(slug, root, path, branch, merged, failed, append: append, homey: true) if merged.any?
    end

    # The run is red without any member's changes, so no member is to blame: say why on the
    # items (once per base commit) and leave them ready, to be bundled when the base is green.
    def red_base(slug, path, base, sha, members, why, seen)
      told = seen ? seen[:told] : Set.new
      @logger.warn("[work-queue] bundle #{path}: base #{base} is red, nobody blamed: #{why}")
      log(slug, members.map(&:item).reject { |i| told.include?(i.n) },
          "Not bundled yet, and no item is blamed: the bundle's base (#{base}) is red or its tests could not run here. #{why}. " \
          "Still ready to bundle; tried again when the base changes.")
      @red_bases[[slug, path]] = { sha: sha, at: Time.current, told: told | members.map { |m| m.item.n } }
      nil
    end

    # An item's own repo (set when it lives in a different repo than its project), else the project's.
    def repo_of(item) = item.repo.presence || @repo_for.call(item.slug)

    def solo_branch(item) = "bundle/#{item.n}-#{item.title.parameterize.first(40)}"

    def candidate?(i) = i.ready_to_bundle? && i.bundle_info.blank?

    # Shipped, cancelled, already-bundled, own-PR and branchless (relay/answer) items aren't part of a new bundle.
    def member?(i)
      return false if i.yours? || IGNORE.include?(i.status) || i.status == "done" || i.bundle_info.present? || i.pr.present?

      i.ready_to_bundle? || i.branch.present? || WAIT.include?(i.status)
    end

    # Branch of this root's bundle whose PR is still open (its members are in review), if any.
    def open_bundle(root, items)
      tree(root, items).find { |i| i.bundle_info["pr"].present? && i.status == "review" }&.bundle_info&.dig("branch")
    end

    # The open bundle's branch when there is one (the follow-up joins the parent's PR); otherwise
    # bundle/<root>-<slug>, with a -2, -3… suffix when an earlier bundle of this root already used it.
    def branch_for(root, items)
      open = open_bundle(root, items)
      return open if open

      name = "bundle/#{root.n}-#{root.title.parameterize.first(40)}"
      used = tree(root, items).filter_map { |i| i.bundle_info["branch"] }.uniq
      used.empty? ? name : "#{name}-#{used.size + 1}"
    end

    def root_of(item, by_n)
      seen = Set.new
      while (up = by_n[item.parent]) && seen.add?(item.n)
        item = up
      end
      item
    end

    def tree(root, items)
      kids = items.select { |i| i.parent == root.n }.sort_by(&:n)
      [root] + kids.flat_map { |k| tree(k, items) }
    end

    # Starts from the open bundle branch when appending to it, else from main.
    def setup(repo, path, onto: nil)
      fresh = GitInfo.fresh_base(repo, onto: onto, git: ->(*args) { git(repo, *args) })
      @logger.warn("[work-queue] bundle #{path}: git fetch origin failed; starting from #{fresh.ref} as last fetched") if fresh.fetch_failed
      base = fresh.ref
      cleanup(repo, path)
      git(repo, "worktree", "add", "--detach", path, base)
      link_shared(repo, path)
      base
    end

    # A fresh worktree has none of the repo's git-ignored files, and the suite cannot run without
    # some of them. Links them in from the main checkout; only ignored paths, so a bundle's content never changes.
    def link_shared(repo, path)
      ProjectEnv.link_shared(repo, path, git: ->(cwd, *args) { git(cwd, *args) })
    rescue SystemCallError => e
      @logger.warn("[work-queue] bundle #{path}: could not link shared files: #{e.message}")
    end

    def cleanup(repo, path)
      git(repo, "worktree", "remove", "--force", path) if File.directory?(path)
      git(repo, "worktree", "prune")
    end

    # Merges every member; a conflict gets one Claude resolution attempt, else that member is left out.
    def merge_all(path, branch, base, members)
      git(path, "checkout", "-B", branch, base)
      merged = []
      failed = []
      members.each do |m|
        if m.branch.blank?
          failed << [m, "No branch to bundle"]
        elsif merge(path, m)
          merged << m
        else
          failed << [m, "Merge conflict with the rest of the bundle that could not be resolved"]
        end
      end
      [merged, failed]
    end

    def merge(path, member)
      ref = git(path, "rev-parse", "--verify", "-q", "origin/#{member.branch}").last ? "origin/#{member.branch}" : member.branch
      return true if git(path, "merge", "--no-ff", "--no-edit", ref).last
      return true if @resolver.call(path, member.branch) && git(path, "diff", "--name-only", "--diff-filter=U").first.strip.empty? &&
                     git(path, "-c", "core.editor=true", "commit", "--no-edit").last

      git(path, "merge", "--abort")
      false
    end

    def rebuild(path, branch, base, members)
      git(path, "reset", "--hard")
      git(path, "checkout", "-B", branch, base)
      members.select { |m| merge(path, m) }
    end

    # [[member, failing output]] for the members whose changes make the run red (red: the
    # failure already seen with all of them merged). Halves are retested separately; when
    # every half is green but the whole is red (an interaction), the later half is blamed
    # so the earlier items still ship.
    def isolate(path, branch, base, members, cmds, red = nil)
      return [] if members.empty?

      red ||= failure(path, cmds) or return []
      return [[members.first, red]] if members.size == 1

      left, right = members.each_slice((members.size / 2.0).ceil).to_a
      bad = [left, right].flat_map do |half|
        rebuild(path, branch, base, half)
        isolate(path, branch, base, half, cmds)
      end
      bad.empty? ? right.map { |m| [m, red] } : bad
    end

    # Why the run is red on the base alone (no member merged), or nil when the base is green.
    def base_failure(path, base, cmds)
      git(path, "reset", "--hard")
      git(path, "checkout", "--detach", base)
      failure(path, cmds)
    end

    # nil when every command passes, else the first failing command with the tail of its output.
    def failure(path, cmds)
      cmds.each do |c|
        out, ok = @shell.call(path, "sh", "-c", c)
        return "`#{c}` failed: #{tail(out)}" unless ok
      end
      nil
    end

    def tail(out)
      lines = out.to_s.scrub.gsub(/\e\[[\d;]*m/, "").lines.map(&:strip).reject { |l| l.match?(/\A[.EFS*]*\z/) }
      lines.last(TAIL_LINES).join(" | ").last(TAIL_CHARS).presence || "(no output)"
    end

    # Full test + lint commands for the bundle's repo.
    def detect_commands(path) = ProjectEnv.suite(path)

    # The PR is opened ready (never a draft) into main: what homey's train counts as ready to batch.
    def publish(slug, root, path, branch, good, failed, append: false, homey: false)
      # Appending only adds commits on top of the open PR's branch, so no force-push.
      _, pushed = append ? git(path, "push", "-u", "origin", branch) : git(path, "push", "--force", "-u", "origin", branch)
      return good.each { |m| fail_member(slug, root, m, "Could not push #{branch}") } unless pushed

      out, ok = @shell.call(path, "gh", "pr", "create", "--base", "main", "--head", branch,
                            "--title", "Bundle ##{root.n}: #{root.title}".truncate(120), "--body", body(root, good, failed, homey: homey))
      url = out.to_s[%r{https://github\.com/[\w.-]+/[\w.-]+/pull/\d+}]
      unless ok && url
        url = @shell.call(path, "gh", "pr", "view", branch, "--json", "url", "-q", ".url").first.to_s.strip.presence
        return good.each { |m| fail_member(slug, root, m, "gh pr create failed: #{out.to_s.strip.truncate(160)}") } unless url
      end

      note = "Bundled → PR #{url}"
      note += ". homey's release train tests it in its next batch and merges it when green" if homey
      good.each do |m|
        @writer.update(slug, m.item.n, log: note) do |i|
          i.delete("readyToBundle")
          i["pr"] = url
          i["bundle"] = { "root" => root.n, "branch" => branch, "pr" => url, "size" => good.size }
        end
      end
    end

    def body(root, good, failed, homey: false)
      ci = homey ? "homey's release train tests it in a batch/** CI run and merges it when green." : "CI runs once for all of them."
      lines = ["Bundle for work-queue item ##{root.n} and its follow-ups. #{ci}", "", "## Items"]
      lines += good.map { |m| "- ##{m.item.n} #{m.item.title} (`#{m.branch}`)" }
      if failed.any?
        lines += ["", "## Left out"]
        lines += failed.map { |m, why| "- ##{m.item.n} #{m.item.title}: #{why}" }
      end
      lines.join("\n")
    end

    def fail_member(slug, root, member, why)
      @writer.update(slug, member.item.n, log: "Left out of bundle ##{root.n}: #{why}") do |i|
        i.delete("readyToBundle")
        i["status"] = "blocked"
        i["bundle"] = { "root" => root.n, "failed" => why }
      end
    end

    def log(slug, items, text)
      return if items.empty?

      items.each { |i| @writer.update(slug, i.n, log: text) }
      nil
    end

    def git(cwd, *args) = @shell.call(cwd, "git", *args)

    # The repo's GitHub name from its origin remote, looked up in homey's projects.yml.
    def homey_batched?(repo)
      url = git(repo, "remote", "get-url", "origin").first.to_s.strip
      HomeyTrain.batched?(url[%r{github\.com[:/]([\w.-]+/[\w.-]+?)(?:\.git)?\z}, 1])
    end

    def sh(cwd, *cmd)
      # git/gh/claude and the suite all run in the project's env, not the runner's myjira Bundler env.
      out, status = Open3.capture2e(ProjectEnv.for(cwd), *cmd, chdir: cwd)
      [out, status.success?]
    rescue SystemCallError => e
      [e.message, false]
    end

    def claude_resolve(cwd, branch)
      prompt = "You are resolving git merge conflicts in this repo (merging #{branch} into a bundle branch). " \
               "Resolve every conflicted file keeping both sides' intent, then `git add` them. Do not commit, push or open a PR."
      _, ok = sh(cwd, "claude", "-p", "--permission-mode", "acceptEdits", "--allowedTools", "Bash(git:*)", "Read", "Edit", "--", prompt)
      ok
    end
  end
end
