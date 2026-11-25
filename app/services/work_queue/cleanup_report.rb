module WorkQueue
  # What the cleanup after deploy (WorktreeCleaner) did for a task, and what its last
  # sweep found that belongs to no task. Written by the cleaner, read by the task
  # detail and the Releases page. Redis only: rendering never runs git or gh.
  class CleanupReport
    Line = Struct.new(:kind, :target, :reason, :detail, keyword_init: true) do
      def label = WorktreeCleaner::LABEL[kind.to_s.to_sym] || kind.to_s
      def to_s = "#{label} #{target}"
    end

    # state: "waiting"  not merged and deployed yet (reason says which)
    #        "due"      merged and deployed; the runner's next pass takes it
    #        "manual"   delivered before the automatic cleanup existed: the sweep's business
    #        "cleaned"  everything it had is removed
    #        "nothing"  looked at, nothing was left to remove (or, with a reason, it is not this machine's to clean)
    #        "left"     something was skipped (skipped says what and why); tried again later
    Task = Struct.new(:state, :at, :removed, :skipped, :reason, keyword_init: true) do
      def left? = state == "left"
      def tone = { "left" => "bad", "cleaned" => "ok", "nothing" => "ok", "due" => "run" }.fetch(state, "wait")

      def label
        { "waiting" => "Cleanup waiting", "due" => "Cleanup due", "manual" => "Cleanup by hand", "cleaned" => "Cleaned up",
          "nothing" => "Nothing to clean up", "left" => "Cleanup left #{skipped.size} #{'thing'.pluralize(skipped.size)}" }[state]
      end
    end

    # One repo's leftovers that belong to no task, as the last sweep saw them.
    Orphans = Struct.new(:repo, :name, :slugs, :at, :dry_run, :removed, :skipped, keyword_init: true)
    Left = Struct.new(:item, :task, keyword_init: true)

    ORPHANS_KEY = "#{RunState::PREFIX}:cleanup_orphans".freeze

    class << self
      # The cleanup state of a done task with a pull request (nil for anything else).
      def for(item)
        return unless item.status == "done" && item.pr.present?

        mark = redis.hgetall(WorktreeCleaner.mark_key(item.key))
        parse(mark["state"]) || unrecorded(item, mark)
      rescue Redis::BaseError
        nil
      end

      # Of these tasks, the ones whose cleanup left something behind.
      def left(items)
        items = items.select { |i| i.status == "done" && i.pr.present? }
        return [] if items.empty?

        raws = redis.pipelined { |p| items.each { |i| p.hget(WorktreeCleaner.mark_key(i.key), "state") } }
        items.zip(raws).filter_map { |item, raw| (task = parse(raw))&.left? ? Left.new(item: item, task: task) : nil }
      rescue Redis::BaseError
        []
      end

      # Per repo, what the last sweep found that belongs to no task (repos with nothing are left out).
      def orphans(slug: nil)
        redis.hgetall(ORPHANS_KEY).filter_map do |repo, raw|
          h = JSON.parse(raw)
          next if slug && Array(h["slugs"]).exclude?(slug)

          Orphans.new(repo: repo, name: h["name"], slugs: Array(h["slugs"]), at: time(h["at"]), dry_run: h["dry_run"],
                      removed: lines(h["removed"]), skipped: lines(h["skipped"]))
        rescue JSON::ParserError
          nil
        end.sort_by(&:repo)
      rescue Redis::BaseError
        []
      end

      # The task's state for the cleaner's Redis marker. What an earlier attempt removed stays listed.
      def dump(result, now, previous: nil)
        before = previous.present? ? Array(JSON.parse(previous)["removed"]) : []
        { at: now.iso8601, removed: (before + result.removed.map { |s| line(s) }).uniq, skipped: result.skipped.map { |s| line(s) },
          ignored: result.ignored }.compact.to_json
      rescue JSON::ParserError
        dump(result, now)
      end

      def store_orphans(repo, name, slugs, result)
        return redis.hdel(ORPHANS_KEY, repo) if result.steps.empty?

        redis.hset(ORPHANS_KEY, repo, { name: name, slugs: slugs, at: Time.current.iso8601, dry_run: result.dry_run,
                                        removed: result.removed.map { |s| line(s) }, skipped: result.skipped.map { |s| line(s) } }.to_json)
      end

      private

      def redis = RunState.redis

      def line(step) = { kind: step.kind, target: step.target, reason: step.reason, detail: step.detail }.compact

      def lines(rows) = Array(rows).map { |r| Line.new(**r.symbolize_keys.slice(:kind, :target, :reason, :detail)) }

      def time(raw) = raw.presence && Time.zone.parse(raw.to_s)

      def parse(raw)
        return if raw.blank?

        h = JSON.parse(raw)
        removed = lines(h["removed"])
        skipped = lines(h["skipped"])
        Task.new(state: skipped.any? ? "left" : (removed.any? ? "cleaned" : "nothing"), at: time(h["at"]), removed: removed, skipped: skipped,
                 reason: h["ignored"])
      rescue JSON::ParserError, ArgumentError
        nil
      end

      # No recorded outcome yet: say what the cleanup is waiting for.
      def unrecorded(item, mark)
        blank = { removed: [], skipped: [] }
        return Task.new(state: "manual", **blank) if mark["done"] == "before"
        return Task.new(state: "cleaned", at: time(mark["done"]), **blank) if mark["done"].present?

        pr = StatusCache.pr(item.pr)
        wait = WorktreeCleaner.waiting(pr, StatusCache.delivery(item.pr), pr&.repo.presence && Delivery.summary(pr.repo))
        return Task.new(state: "waiting", reason: wait, **blank) if wait

        Task.new(state: before_tick?(pr) ? "manual" : "due", **blank)
      rescue ArgumentError
        nil
      end

      # Merged before the runner's cleanup first ran: the tick never takes those.
      def before_tick?(pr)
        since = redis.get("#{RunState::PREFIX}:cleanup_since").presence or return false
        merged_at = pr.merged_at.presence && Time.zone.parse(pr.merged_at.to_s)
        merged_at.nil? || merged_at < Time.zone.at(since.to_f)
      end
    end
  end
end
