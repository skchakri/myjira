module WorkQueue
  class WorktreeCleaner
    # The sweep's second pass: leftovers that belong to no task.
    #
    #   * agent worktrees: every worktree under <repo>/.claude/worktrees (Claude's
    #     isolated agents leave them behind), with the branch each had checked out;
    #   * bundle worktrees: <repo>-bundle-<n> whose task <n> is no longer open;
    #   * local branches named worktree-agent-* that nothing has checked out.
    #
    # Whatever an open task, or a done task with a pull request, names as its branch is
    # not looked at here: the per-task cleanup owns that.
    #
    # The safety bar is the per-task one (same blockers, same removals), and the proof
    # that nothing is lost is per branch: its tip is on origin's default branch, or is
    # contained in the head of a merged pull request opened from that branch name
    # (squash merges leave no ancestry on main). No proof, no removal: the reason is
    # reported. A directory under .claude/worktrees that git no longer knows as a
    # worktree is only reported; its state cannot be checked, so it is never deleted.
    #
    # Only the sweep runs this (dry run unless DRY_RUN=0); the runner's tick never does.
    module Orphans
      AGENT_BRANCH = /\Aworktree-agent-[A-Za-z0-9_.-]+\z/
      UNPROVEN = "it has commits that are neither on origin's default branch nor in a merged pull request".freeze
      # Stands in for a pull request when the proof is "already on origin's default branch".
      OnDefault = Struct.new(:repo, :base, :head_sha, :merge_sha, :number, keyword_init: true)

      private

      # Every repo the queue knows, once each. Results land in #orphan_results (repo => Result)
      # and in Redis for the Releases page.
      def sweep_orphans(dry_run:)
        items = @store.all
        repos = Hash.new { |h, k| h[k] = [] }
        items.each { |i| (repo = main_checkout(i)) && (repos[repo] |= [i.slug]) }
        repos.sort.each do |repo, slugs|
          result = orphans(repo, items.select { |i| slugs.include?(i.slug) && main_checkout(i) == repo }, dry_run: dry_run)
          @orphan_results[repo] = result
          CleanupReport.store_orphans(repo, origin_name(repo), slugs, result)
        rescue StandardError => e
          @logger.error("[work-queue] orphan sweep #{repo} failed: #{e.class}: #{e.message}")
        end
      end

      def orphans(repo, items, dry_run:)
        result = Result.new(repo: repo, steps: [], dry_run: dry_run)
        trees = worktrees(repo)
        main = trees.find(&:main) or return result
        name = origin_name(repo)
        default = default_branch(repo)
        git(repo, "fetch", "-q", "origin", default, net: true) # proof is read off origin's default branch: have it current
        leftovers?(repo, []) # one listing of origin's branches for the whole pass
        kept = (ALWAYS_KEPT + [default, main.branch]).compact.uniq
        claimed = items.select { |i| i.open? || (i.status == "done" && i.pr.present?) }
                       .flat_map { |i| [i.branch, i.bundle_info["branch"]] }.filter_map { |b| b.to_s.strip.presence }.to_set
        gone = @handled.filter_map { |r, kind, path| path if r == repo && kind == :worktree }

        stale = stale_worktrees(main.path, trees, items, claimed) - trees.select { |t| gone.include?(t.path) }
        stale.each { |tree| orphan_worktree(result, repo, name, tree, gone) }
        unregistered(result, main.path, trees)

        held = trees.reject { |t| gone.include?(t.path) }.filter_map(&:branch)
        names = agent_branches(repo) + stale.select { |t| gone.include?(t.path) }.filter_map(&:branch)
        (names.uniq - kept - claimed.to_a - held).each { |branch| orphan_branch(result, repo, name, branch, trees, gone) }
        git(repo, "worktree", "prune") if gone.any? && !dry_run
        result
      end

      # Agent and bundle worktrees that no open (or still-to-be-cleaned) task accounts for.
      def stale_worktrees(root, trees, items, claimed)
        open = items.select(&:open?).map(&:n)
        trees.reject(&:main).select do |tree|
          next false if tree.branch && claimed.include?(tree.branch)

          bundle = tree.path[/\A#{Regexp.escape(root)}-bundle-(\d+)\z/, 1]
          bundle ? open.exclude?(bundle.to_i) : tree.path.start_with?("#{agent_root(root)}/")
        end
      end

      def agent_root(root) = File.join(root, ".claude", "worktrees")

      def agent_branches(repo)
        git(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/worktree-agent-*").first.split("\n").grep(AGENT_BRANCH)
      end

      def orphan_worktree(result, repo, name, tree, gone)
        return remove_worktree(result, repo, tree, gone) unless File.directory?(tree.path) # only the entry is left

        proof, why, detail = shipped(repo, name, tree.branch, tree.head)
        return remove_worktree(result, repo, tree, gone) if proof

        skip(result, :worktree, tree.path, why, detail)
      end

      def orphan_branch(result, repo, name, branch, trees, gone)
        return unless branch.match?(BRANCH) && branch.exclude?("..")

        sha, ok = git(repo, "rev-parse", "--verify", "-q", "refs/heads/#{branch}")
        if ok && @handled.exclude?([repo, :local, branch])
          proof, why, detail = shipped(repo, name, branch, sha)
          proof ? delete_local(result, repo, branch, sha, trees, gone) : skip(result, :local, branch, why, detail)
        end
        orphan_remote(result, repo, name, branch)
      end

      # The same-named branch on origin, judged by its own commit there.
      def orphan_remote(result, repo, name, branch)
        return if @handled.include?([repo, :remote, branch])

        sha = remote_sha(repo, branch)
        return skip(result, :remote, branch, "origin could not be reached") if sha.nil?
        return if sha.blank?

        proof, why, detail = shipped(repo, name, branch, sha)
        proof ? delete_remote(result, repo, branch, proof) : skip(result, :remote, branch, why, detail)
      end

      # Directories under .claude/worktrees that are not worktrees (any more). Never removed.
      def unregistered(result, root, trees)
        dir = agent_root(root)
        return unless File.directory?(dir)

        known = trees.map(&:path)
        Dir.children(dir).sort.map { |c| File.join(dir, c) }.each do |path|
          next if known.include?(path) || File.symlink?(path) || !File.directory?(path)

          foreign = @foreign.call(path)
          next skip(result, :worktree, path, FOREIGN_FILES, foreign.delete_prefix("#{path}/").truncate(100)) if foreign

          skip(result, :worktree, path, "git no longer knows it as a worktree, so its state cannot be checked; remove it by hand")
        end
      rescue SystemCallError
        nil
      end

      # Proof that every commit of `sha` shipped => [proof] or [nil, why, detail]. The proof
      # quacks like a pull request (repo, head_sha, merge_sha, base) for #contained? and #delete_remote.
      def shipped(repo, name, branch, sha)
        at = "#{branch || 'detached'} at #{sha.to_s[0, 7]}"
        on_default = OnDefault.new(repo: name, base: default_branch(repo))
        return [on_default] if sha.present? && contained?(repo, sha, on_default)
        return [nil, "it is detached at commits that are not on origin's default branch", at] if branch.blank?
        return [nil, "it has commits that are not on origin's default branch, and origin names no GitHub repo to ask", at] if name.blank?

        merged = merged_prs(name, branch)
        return [nil, "GitHub could not be asked for its merged pull request", at] if merged.nil?

        proof = merged.find { |pr| contained?(repo, sha, pr) }
        return [proof] if proof
        return [nil, UNPROVEN, at] if merged.empty?

        [nil, "it has commits its merged pull request never contained", "#{at}, PR ##{merged.first.number} head #{merged.first.head_sha.to_s[0, 7]}"]
      end

      # Merged pull requests opened from this branch name, asked once per branch and only for
      # a branch that is not already on origin's default branch. nil = GitHub could not be asked.
      def merged_prs(name, branch)
        @merged_prs ||= {}
        key = [name, branch]
        return @merged_prs[key] if @merged_prs.key?(key)
        return @merged_prs[key] = nil if Delivery.paused_until

        out, ok = @gh.call("pr", "list", "-R", name, "--state", "merged", "--head", branch, "--limit", "20",
                           "--json", "number,url,baseRefName,headRefName,headRefOid,mergeCommit,mergedAt")
        @merged_prs[key] = ok ? JSON.parse(out).select { |j| j["headRefName"] == branch }.map { |j| merged_status(j) } : nil
      rescue JSON::ParserError
        @merged_prs[key] = nil
      end

      def merged_status(json)
        PullRequests::Status.new(url: json["url"], number: json["number"], state: "MERGED", base: json["baseRefName"],
                                 head: json["headRefName"], head_sha: json["headRefOid"],
                                 merge_sha: json.dig("mergeCommit", "oid"), merged_at: json["mergedAt"])
      end

      # "owner/name" of origin (the last two segments of its URL), nil without an origin.
      def origin_name(repo)
        url, ok = git(repo, "remote", "get-url", "origin")
        ok ? url.sub(/\.git\z/, "")[%r{([^/:]+/[^/:]+)\z}, 1] : nil
      end
    end
  end
end
