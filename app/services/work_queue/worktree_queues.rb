module WorkQueue
  # A git worktree is a second checkout of a repo, never a project of its own.
  # A session that ran inside one could still write a queue file named after the
  # worktree folder (the mod has since been fixed, but any stray file would show
  # up as its own project block). This folds each such file into its parent
  # repo's queue and moves the stray file to <queues>/archive/ (never deleted).
  #
  #   WorkQueue::WorktreeQueues.new.call            # fold every stray file
  #   WorkQueue::WorktreeQueues.origin(slug)        # nil unless slug is a worktree's
  #
  # Slugs are lossy (every path separator became a dash), so a slug only counts as
  # a worktree's when it ends in "-wq-<n>" or contains "-claude-worktrees-", AND
  # the parent slug it points at has a queue file or is the repo of a myjira project.
  #
  # Moved items are renumbered after the parent's highest n. When the worktree is
  # "<repo>-wq-<N>" and the parent queue has item N, items that had no parent of
  # their own become follow-ups of N. Every moved item records where it came from
  # ("foldedFrom"), so a stray file that reappears is never folded in twice.
  class WorktreeQueues
    INSIDE = /-claude-worktrees-.+\z/
    SIBLING = /-wq-(\d+)\z/
    MARK = /-wq-\d+\z|-claude-worktrees-/

    Origin = Struct.new(:slug, :parent, :item, keyword_init: true)
    Fold = Struct.new(:slug, :parent, :moved, :skipped, :under, :archive, keyword_init: true)

    # Where a worktree-named slug belongs: Origin(parent slug, queue item number
    # for a "-wq-<n>" worktree), or nil when the slug is not a worktree's.
    def self.origin(slug, dir: Store.dir)
      slug = slug.to_s
      return unless slug.match?(MARK)

      dir = Pathname(dir)
      known = ->(s) { s.present? && (dir.join("#{s}.json").exist? || Workspace.repo_for(s).present?) }
      parent = slug.sub(INSIDE, "")
      item = nil
      if (sibling = parent.match(SIBLING)) && known.call(sibling.pre_match)
        parent = sibling.pre_match
        item = sibling[1].to_i
      end
      Origin.new(slug: slug, parent: parent, item: item) if parent != slug && known.call(parent)
    end

    def self.worktree?(slug, dir: Store.dir) = origin(slug, dir: dir).present?

    def initialize(dir: Store.dir, writer: nil, logger: Rails.logger)
      @dir = Pathname(dir)
      @writer = writer || QueueWriter.new(dir: @dir)
      @logger = logger
    end

    # Folds every worktree-named queue file; returns one Fold per file it moved.
    def call
      Dir.glob(@dir.join("*.json")).sort.filter_map { |f| fold(Store.slug_for(f)) }
    end

    def fold(slug)
      origin = self.class.origin(slug, dir: @dir) or return
      file = @dir.join("#{slug}.json")
      result = nil
      # Hold the stray file's own lock from the read to the archive, so nothing
      # written through the lock in between is archived unfolded.
      File.open("#{file}.lock", File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        source = file.exist? ? read(file) : nil
        if source
          result = move(origin, source)
          result.archive = archive(file)
        end
        FileUtils.rm_f(lock.path) unless file.exist?
      end
      @logger.info("[work-queue] folded worktree queue #{slug} into #{origin.parent}: #{result.moved} moved, #{result.skipped} already there") if result
      result
    rescue StandardError => e
      @logger.error("[work-queue] folding worktree queue #{slug} failed: #{e.class}: #{e.message}")
      nil
    end

    private

    # The file's item hashes, or nil when it cannot be read right now (mid-write).
    def read(file)
      data = JSON.parse(File.read(file))
      raw = data.is_a?(Hash) ? Array(data["items"]) : Array(data)
      raw.select { |h| h.is_a?(Hash) && h["n"] }
    rescue JSON::ParserError, Errno::ENOENT
      nil
    end

    def move(origin, source)
      fold = Fold.new(slug: origin.slug, parent: origin.parent, moved: 0, skipped: 0)
      @writer.transaction(origin.parent) do |items|
        # { [old n, createdAt] => new n } for items of this worktree already in the parent.
        numbers = items.each_with_object({}) do |i, map|
          from = i["foldedFrom"]
          map[[from["n"], from["createdAt"]]] = i["n"] if from.is_a?(Hash) && from["slug"] == origin.slug
        end
        fresh = source.reject { |i| numbers.key?([i["n"], i["createdAt"]]) }
        top = items.map { |i| i["n"].to_i }.max || 0
        fresh.each_with_index { |i, k| numbers[[i["n"], i["createdAt"]]] = top + k + 1 }
        renumber = source.to_h { |i| [i["n"], numbers[[i["n"], i["createdAt"]]]] }
        fold.under = origin.item if origin.item && items.any? { |i| i["n"].to_i == origin.item }
        now = (Time.now.to_f * 1000).to_i
        fresh.each { |i| items << relocate(i, origin, renumber, fold.under, now) }
        fold.moved = fresh.size
        fold.skipped = source.size - fresh.size
      end
      fold
    end

    def relocate(source, origin, renumber, under, now)
      item = source.deep_dup
      was = source["n"]
      item["n"] = renumber[was]
      note = "Moved here from the worktree queue #{origin.slug} (was ##{was} there)"
      if renumber[source["parent"]]
        item["parent"] = renumber[source["parent"]]
      elsif under
        item["parent"] = under
        # Not started yet: a nice-to-have, so the person picks Start or Drop; it never starts by itself.
        item["followUp"] = { "priority" => "nice" } if unstarted?(item) && !item["followUp"].is_a?(Hash)
        note += "; filed as a follow-up of ##{under}"
      else
        item.delete("parent")
      end
      merged = renumber[source["mergedInto"]]
      merged ? item["mergedInto"] = merged : item.delete("mergedInto")
      item["foldedFrom"] = { "slug" => origin.slug, "n" => was, "createdAt" => source["createdAt"] }
      item["log"] = Array(item["log"]) << { "at" => now, "text" => note }
      item["updatedAt"] = now
      item
    end

    def unstarted?(item) = %w[triage queued].include?(item["status"]) && item["agent"].blank?

    def archive(file)
      folder = @dir.join("archive")
      FileUtils.mkdir_p(folder)
      match_owner(folder)
      name = File.basename(file.to_s, ".json")
      dest = folder.join("#{name}.json")
      dest = folder.join("#{name}-#{Time.now.strftime('%Y%m%d%H%M%S%L')}.json") if dest.exist?
      File.rename(file, dest)
      dest.to_s
    end

    # Running as root in the container: keep the archive owned like the queue dir.
    def match_owner(path)
      return unless Process.uid.zero?

      st = File.stat(@dir)
      File.chown(st.uid, st.gid, path)
    rescue SystemCallError
      nil
    end
  end
end
