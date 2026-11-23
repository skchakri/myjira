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
  class Bundler
    WAIT = %w[triage queued running blocked].freeze
    IGNORE = %w[dropped merged].freeze
    Member = Struct.new(:item, :branch)

    # shell: ->(cwd, *cmd) { [output, ok] }; resolver: ->(cwd, branch) { ok }
    def initialize(store: Store.new, writer: QueueWriter.new, logger: Rails.logger, shell: nil, resolver: nil, repo_for: nil, commands: nil)
      @store = store
      @writer = writer
      @logger = logger
      @shell = shell || method(:sh)
      @resolver = resolver || method(:claude_resolve)
      @repo_for = repo_for || Workspace.method(:repo_for)
      @commands = commands || method(:detect_commands)
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

    def ship(slug, root, items, branch)
      repo = @repo_for.call(slug) or return @logger.warn("[work-queue] bundle #{slug}:#{root.n} waiting: no repo_path")
      path = "#{repo}-bundle-#{root.n}"
      members = items.map { |i| Member.new(i, i.branch) }
      log(slug, items, "Bundling #{items.size} item(s) into #{branch}")

      base = setup(repo, path)
      merged, failed = merge_all(path, branch, base, members)
      cmds = @commands.call(path)
      bad = cmds.any? ? isolate(path, branch, base, merged, cmds) : []
      failed += bad.map { |m| [m, "Breaks the bundle's test/lint run (#{cmds.join(' && ')})"] }
      good = merged - bad
      if bad.any? && good.any?
        rebuild(path, branch, base, good)
        unless green?(path, cmds)
          failed += good.map { |m| [m, "Bundle still red after removing the failing items"] }
          good = []
        end
      end
      failed.each { |m, why| fail_member(slug, root, m, why) }
      publish(slug, root, path, branch, good, failed) if good.any?
    ensure
      cleanup(repo, path) if repo && path
    end

    private

    def candidate?(i) = i.ready_to_bundle? && i.bundle_info.blank?

    # Shipped, cancelled, already-bundled, own-PR and branchless (relay/answer) items aren't part of a new bundle.
    def member?(i)
      return false if IGNORE.include?(i.status) || i.status == "done" || i.bundle_info.present? || i.pr.present?

      i.ready_to_bundle? || i.branch.present? || WAIT.include?(i.status)
    end

    # bundle/<root>-<slug>, with a -2, -3… suffix when an earlier bundle of this root already used it.
    def branch_for(root, items)
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

    def setup(repo, path)
      git(repo, "fetch", "origin", "--prune")
      base = %w[origin/main main origin/master master].find { |b| git(repo, "rev-parse", "--verify", "-q", b).last } || "HEAD"
      cleanup(repo, path)
      git(repo, "worktree", "add", "--detach", path, base)
      base
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

    # Members whose changes make the run red. Halves are retested separately;
    # when every half is green but the whole is red (an interaction), the later
    # half is blamed so the earlier items still ship.
    def isolate(path, branch, base, members, cmds)
      return [] if members.empty? || green?(path, cmds)
      return members if members.size == 1

      left, right = members.each_slice((members.size / 2.0).ceil).to_a
      bad = [left, right].flat_map do |half|
        rebuild(path, branch, base, half)
        isolate(path, branch, base, half, cmds)
      end
      bad.empty? ? right : bad
    end

    def green?(path, cmds) = cmds.all? { |c| @shell.call(path, "sh", "-c", c).last }

    # Full test + lint commands for the bundle's repo.
    def detect_commands(path)
      cmds = []
      if File.exist?(File.join(path, "bin/rails"))
        cmds << "bin/rails test"
      elsif File.exist?(File.join(path, "package.json")) && JSON.parse(File.read(File.join(path, "package.json"))).dig("scripts", "test")
        cmds << "npm test"
      end
      cmds << "bin/rubocop" if File.exist?(File.join(path, "bin/rubocop"))
      cmds << "npm run lint" if File.exist?(File.join(path, "package.json")) && JSON.parse(File.read(File.join(path, "package.json"))).dig("scripts", "lint")
      cmds
    rescue JSON::ParserError
      cmds
    end

    def publish(slug, root, path, branch, good, failed)
      _, pushed = git(path, "push", "--force", "-u", "origin", branch)
      return good.each { |m| fail_member(slug, root, m, "Could not push #{branch}") } unless pushed

      out, ok = @shell.call(path, "gh", "pr", "create", "--base", "main", "--head", branch,
                            "--title", "Bundle ##{root.n}: #{root.title}".truncate(120), "--body", body(root, good, failed))
      url = out.to_s[%r{https://github\.com/[\w.-]+/[\w.-]+/pull/\d+}]
      unless ok && url
        url = @shell.call(path, "gh", "pr", "view", branch, "--json", "url", "-q", ".url").first.to_s.strip.presence
        return good.each { |m| fail_member(slug, root, m, "gh pr create failed: #{out.to_s.strip.truncate(160)}") } unless url
      end

      good.each do |m|
        @writer.update(slug, m.item.n, log: "Bundled → PR #{url}") do |i|
          i.delete("readyToBundle")
          i["pr"] = url
          i["bundle"] = { "root" => root.n, "branch" => branch, "pr" => url, "size" => good.size }
        end
      end
    end

    def body(root, good, failed)
      lines = ["Bundle for work-queue item ##{root.n} and its follow-ups. CI runs once for all of them.", "", "## Items"]
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

    def sh(cwd, *cmd)
      out, status = Open3.capture2e(*cmd, chdir: cwd)
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
