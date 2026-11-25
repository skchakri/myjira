module WorkQueue
  # The release view: per GitHub repo, the tasks that are merged but not live yet,
  # that repo's last Deploy run, and one deploy for all of them.
  #
  # Everything is read from Redis (StatusCache per PR, Delivery.summary per repo),
  # both kept current by the watcher's status refresh; rendering never calls gh.
  #
  # A done task counts as "merged, not live" only when its PR is MERGED and the
  # repo's Deploy workflow has no successful run containing it. Tasks are grouped
  # by the repo their PR lives in, so a follow-up filed in another repo lands under
  # that repo, whichever project's queue it sits in.
  class Releases
    PENDING = %w[not_live deploying deploy_failed testing].freeze
    RECENT = 14.days
    DISPATCH_TTL = 20.minutes.to_i

    Entry = Struct.new(:item, :pr, :delivery, keyword_init: true) do
      def state = delivery&.state
      def merged_at = (pr.merged_at.presence && Time.zone.parse(pr.merged_at.to_s)) || item.updated_at
      # Set when the task shipped inside its parent's bundle PR rather than a PR of its own.
      def bundle_root = item.bundle_info["pr"].present? ? item.bundle_info["root"] : nil
    end

    Repo = Struct.new(:name, :entries, :summary, :dispatched_at, keyword_init: true) do
      def workflow = summary&.workflow
      def prs = entries.map { |e| e.item.pr }.uniq
      def slugs = entries.map { |e| e.item.slug }.uniq

      # "deploying" | "failed" | "ready"
      def state
        return "deploying" if dispatch_pending? || entries.any? { |e| e.state == "deploying" } || summary&.run_state == "running"
        return "failed" if entries.any? { |e| e.state == "deploy_failed" }

        "ready"
      end

      # A deploy sent from here that GitHub has not shown as a run yet.
      def dispatch_pending?
        dispatched_at.present? && (summary&.run_at.nil? || summary.run_at < dispatched_at - 5.seconds)
      end

      # A repo deployed by hand (kamal deploy, recorded as GitHub Deployments) has nothing to dispatch.
      def by_hand? = summary&.deployments? || false
      def deployable? = state != "deploying" && entries.any? && !by_hand?
    end

    # A repo's tasks that cannot be released from here (no Deploy workflow, or merged into a branch off main).
    Loose = Struct.new(:name, :entries, keyword_init: true)

    def self.dispatch_key(repo) = "#{RunState::PREFIX}:release-dispatch:#{repo}"

    def initialize(store: Store.new, slug: nil, now: Time.current)
      @store = store
      @slug = slug.presence
      @now = now
    end

    # Repos with a Deploy workflow and at least one merged-not-live task, most waiting first.
    def repos
      build
      @repos
    end

    # Repos without a Deploy workflow that had tasks merged in the last 14 days.
    def no_workflow
      build
      @no_workflow
    end

    # Tasks whose PR was merged into another branch that is not on main yet (a stacked
    # PR whose parent is unmerged): a deploy of main would not ship them.
    def stacked
      build
      @stacked
    end

    # Done tasks whose PR was closed without merging: they shipped some other way
    # (a release-train batch) or were abandoned; GitHub cannot say which.
    def closed_unmerged
      build
      @closed_unmerged
    end

    # Done tasks with a PR nobody has looked up yet (no cached status).
    def unknown
      build
      @unknown
    end

    def pending_count = repos.sum { |r| r.entries.size }

    def repo(name) = repos.find { |r| r.name == name }

    # Other merged-not-live tasks that a deploy of this task's repo would also ship.
    def others_for(item)
      name = StatusCache.pr(item.pr)&.repo or return []
      (repo(name)&.entries || []).reject { |e| e.item.key == item.key }
    end

    # One Deploy run for the whole repo, with a note on every task it ships.
    # => [ok, message]
    def deploy(name, delivery: Delivery.new, writer: QueueWriter.new)
      group = repo(name) or return [false, "#{name} has nothing merged and waiting"]
      return [false, "#{name} is already deploying"] unless group.deployable?

      ok, message = delivery.deploy_repo(name)
      note = "Release: #{message} (#{group.entries.size} merged #{'task'.pluralize(group.entries.size)} from myjira)"
      if ok
        RunState.redis.set(self.class.dispatch_key(name), @now.iso8601, ex: DISPATCH_TTL)
        group.entries.each do |entry|
          writer.update(entry.item.slug, entry.item.n, log: note)
          Broadcaster.item_note(entry.item, note)
        rescue ArgumentError, SystemCallError
          next # the item vanished from its queue file; the deploy itself went out
        end
      end
      [ok, ok ? "#{message} for #{name}: #{group.entries.size} #{'task'.pluralize(group.entries.size)} going out" : message]
    end

    private

    def build
      return if @repos

      pending = Hash.new { |h, k| h[k] = [] }
      loose = Hash.new { |h, k| h[k] = [] }
      @closed_unmerged = []
      @unknown = []
      summaries = Hash.new { |h, repo| h[repo] = Delivery.summary(repo) }
      stacked = Hash.new { |h, k| h[k] = [] }
      candidates.each { |item| sort(item, pending, loose, stacked, summaries) }
      @stacked = stacked.map { |name, entries| Loose.new(name: name, entries: entries.sort_by { |e| e.item.n }) }.sort_by(&:name)

      @repos = pending.map do |name, entries|
        Repo.new(name: name, entries: entries.sort_by { |e| [e.merged_at || @now, e.item.n] },
                 summary: summaries[name], dispatched_at: dispatched_at(name))
      end.sort_by { |r| [-r.entries.size, r.name] }
      @no_workflow = loose.map { |name, entries| Loose.new(name: name, entries: entries.sort_by { |e| -e.item.updated_at.to_i }) }
                          .sort_by(&:name)
    end

    def candidates
      items = @slug ? @store.items_for(@slug) : @store.all
      items.select { |i| i.status == "done" && i.pr.present? }
    end

    def sort(item, pending, loose, stacked, summaries)
      pr = StatusCache.pr(item.pr)
      return @unknown << item if pr.nil? || pr.repo.blank?
      return @closed_unmerged << item unless pr.merged?

      delivery = StatusCache.delivery(item.pr)
      entry = Entry.new(item: item, pr: pr, delivery: delivery)
      if PENDING.include?(delivery&.state)
        pending[pr.repo] << entry
      elsif delivery&.state == "stacked"
        stacked[pr.repo] << entry
      elsif delivery.nil? && recent?(item) && (summary = summaries[pr.repo]) && !summary.workflow?
        loose[pr.repo] << entry
      end
    end

    def recent?(item) = item.updated_at.present? && item.updated_at > @now - RECENT

    def dispatched_at(name)
      raw = RunState.redis.get(self.class.dispatch_key(name))
      raw.presence && Time.zone.parse(raw)
    rescue Redis::BaseError, ArgumentError
      nil
    end
  end
end
