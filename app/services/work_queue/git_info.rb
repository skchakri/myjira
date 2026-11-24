require "open3"

module WorkQueue
  # Where an item's work lives in git: repo, branch, the base it was branched
  # from (+ that commit's short SHA), ahead/behind vs base and vs main,
  # worktree path, and whether the branch conflicts with its base.
  #
  # The worktree is the agent's working directory (the last `cwd` its
  # transcript recorded). Results are cached briefly (Rails cache: repetitive data).
  class GitInfo
    Info = Struct.new(:repo, :worktree, :branch, :base, :base_sha, :ahead, :behind,
                      :main, :main_ahead, :main_behind, :conflicts, keyword_init: true) do
      def base_not_main? = base.present? && base != main
      def behind? = behind.to_i.positive? || main_behind.to_i.positive?
      def warn? = base_not_main? || behind.to_i.positive? || conflicts
    end

    TTL = 20.seconds

    def self.for(worktree, pr_base: nil)
      return if worktree.blank? || !File.directory?(worktree)

      Rails.cache.fetch(["wq-git", worktree, pr_base, head(worktree)], expires_in: TTL) { new(worktree, pr_base).info }
    end

    # Uncached: for the watcher's background refresh (StatusCache).
    def self.compute(worktree, pr_base: nil)
      return if worktree.blank? || !File.directory?(worktree)

      new(worktree, pr_base).info
    end

    def self.head(dir) = git(dir, "rev-parse", "HEAD").first

    # One cheap git call that changes whenever anything `compute` reads could have
    # changed: this worktree's HEAD and every local branch tip. nil = not a repo.
    def self.signature(worktree)
      return if worktree.blank? || !File.directory?(worktree)

      out, ok = git(worktree, "show-ref", "--head", "--heads")
      ok ? out.hash : nil
    end

    def self.git(dir, *args)
      out, status = Open3.capture2("git", "-c", "safe.directory=*", "-C", dir.to_s, *args, err: File::NULL)
      [out.strip, status.success?]
    rescue SystemCallError
      ["", false]
    end

    def initialize(worktree, pr_base)
      @dir = worktree
      @pr_base = pr_base
    end

    def info
      top, ok = git("rev-parse", "--show-toplevel")
      return unless ok

      branch = git("rev-parse", "--abbrev-ref", "HEAD").first
      common = File.expand_path(git("rev-parse", "--git-common-dir").first, top)
      main = %w[main master].find { |b| git("rev-parse", "--verify", "-q", b).last } || "main"
      base = @pr_base.presence || guess_base(branch, main)
      ahead, behind = counts(base)
      m_ahead, m_behind = base == main ? [ahead, behind] : counts(main)
      Info.new(repo: File.basename(File.dirname(common.sub(%r{/\.git\z}, "/.git"))), worktree: top, branch: branch,
               base: base, base_sha: git("merge-base", base, "HEAD").first[0, 7].presence,
               ahead: ahead, behind: behind, main: main, main_ahead: m_ahead, main_behind: m_behind,
               conflicts: conflicts?(base))
    end

    private

    def git(*args) = self.class.git(@dir, *args)

    # The local branch whose tip is the closest ancestor-side neighbour: the one
    # HEAD has the fewest commits beyond. Ties go to main.
    def guess_base(branch, main)
      # git >= 2.41 answers "how far is HEAD beyond each branch" in one call
      # (two git calls per branch otherwise, which made a full compute ~60 calls).
      out, ok = git("for-each-ref", "--sort=-committerdate", "--count=40", "--format=%(refname:short)\t%(ahead-behind:HEAD)", "refs/heads")
      rows = ok ? out.split("\n").filter_map { |l| (name, counts = l.split("\t")) && counts.to_s[/\A\d+ (\d+)\z/, 1] && [name, counts.split.last.to_i] } : []
      if rows.any?
        beyond = rows.to_h
        beyond[main] ||= git("rev-list", "--count", "#{main}..HEAD").first.to_i
        return (beyond.keys - [branch]).min_by { |b| [beyond[b], b == main ? 0 : 1] } || main
      end

      candidates = git("for-each-ref", "--sort=-committerdate", "--count=40", "--format=%(refname:short)", "refs/heads").first.split("\n")
      candidates = ([main] + candidates).uniq - [branch]
      candidates.min_by do |b|
        mb = git("merge-base", b, "HEAD").first
        n = mb.present? ? git("rev-list", "--count", "#{mb}..HEAD").first.to_i : 1_000_000
        [n, b == main ? 0 : 1]
      end || main
    end

    def counts(ref)
      out, ok = git("rev-list", "--left-right", "--count", "#{ref}...HEAD")
      return [nil, nil] unless ok

      behind, ahead = out.split.map(&:to_i)
      [ahead, behind]
    end

    # git >= 2.38: merge-tree --write-tree exits 1 on conflicts, without touching the tree.
    def conflicts?(ref)
      _, status = Open3.capture2("git", "-c", "safe.directory=*", "-C", @dir, "merge-tree", "--write-tree", ref, "HEAD", err: File::NULL)
      status.exitstatus == 1
    rescue SystemCallError
      false
    end
  end
end
