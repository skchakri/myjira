module WorkQueue
  # Everything a card / log header needs about an item beyond the queue JSON:
  # transcript path, worktree + git status, PR status, open dependencies.
  class ItemContext
    attr_reader :item

    # Items whose label depends on cached run / PR / deploy state: open ones, and
    # recently merged ones that may not be live yet. Older done items read "Live".
    def self.wanted?(item)
      item.open? || (item.status == "done" && item.pr.present? && item.updated_at.present? && item.updated_at > 14.days.ago)
    end

    def initialize(item, store:, prs: PullRequests.new)
      @item = item
      @store = store
      @prs = prs
    end

    def server_run? = @server_run.nil? ? (@server_run = RunState.server_run?(item.key)) : @server_run
    def run = @run ||= RunState.get(item.key)
    def phases = @phases ||= RunState.phases(item.key)

    def transcript_path = @transcript_path ||= Transcript.path_for(item)

    # Latest sign of life: the queue file's timestamp, the last queue log line, or a write
    # to the item's transcript (CLI-session items log there without touching the queue).
    def last_activity
      @last_activity ||= [item.updated_at, log_time, transcript_time].compact.max
    end

    # A headless phase is running on the server right now (the runner clears pid when a
    # phase ends, and its heartbeat key expires within seconds of it going down).
    def live_pid? = run["pid"].present? && RunState.runner.present?
    def worktree = @worktree ||= run["worktree"].presence || Transcript.cwd_for(transcript_path)
    # Both read the background-refreshed StatusCache; rendering never runs git/gh.
    def pr_status = (@pr_status ||= [item.pr && item.open? ? StatusCache.pr(item.pr) : nil]).first
    def delivery = (@delivery ||= [item.pr ? StatusCache.delivery(item.pr) : nil]).first
    def git = (@git ||= [StatusCache.git(item.key)]).first
    def dependencies = @dependencies ||= @store.dependencies(item)
    def flow = @flow ||= Flow.new(item, self)
    def project_items = @project_items ||= @store.items_for(item.slug)
    def progress = @progress ||= Progress.new(project_items, store: @store, flows: { item.key => flow })
    def roll = progress.for(item)

    # Parent chain, root first (breadcrumb).
    def ancestors
      by_n = project_items.index_by(&:n)
      chain = []
      cur = by_n[item.parent]
      while cur && chain.exclude?(cur) && cur.n != item.n
        chain.unshift(cur)
        cur = by_n[cur.parent]
      end
      chain
    end

    # Direct follow-ups (child steps), oldest first; shown under "What's happening".
    def children = project_items.select { |i| i.parent == item.n && i.n != item.n }.sort_by(&:n)

    # [[kind, item]] for the Related tasks box: parent, siblings, linked (children are listed under "What's happening").
    def related
      parent = project_items.find { |i| i.n == item.parent }
      rows = []
      rows << ["Parent task", parent] if parent
      project_items.select { |i| parent && i.parent == parent.n && i.n != item.n }.each { |s| rows << ["Sibling", s] }
      RunState.related(item.key).filter_map { |k| @store.find(k) }.each { |r| rows << ["Linked", r] }
      rows.uniq { |_, i| i.key }
    end

    # Merge PR shows on the card only when nothing linked is still open.
    # :flag / :detected / nil — see BrowserStep.
    def browser_step = defined?(@browser_step) ? @browser_step : (@browser_step = BrowserStep.reason(item, run))

    # The item's "Run in Chrome" session while it is starting or running, and when the
    # step last went to the listening CLI instead (see ChromeRun).
    def chrome_launch = defined?(@chrome_launch) ? @chrome_launch : (@chrome_launch = ChromeRun.active_launch(run, key: item.key))
    def chrome_sent_at = ChromeRun.sent_at(run)
    # The item's last "Run in Chrome" launch when it failed (cleared by the next launch).
    def chrome_failure = ChromeRun.failed_launch(run)

    # Why "Run in Chrome" can't reach a Chrome-capable session right now (nil when it can).
    def chrome_blocker
      return nil if Dispatcher.new(item).listening? || SessionLaunch.launcher_alive?

      "The owning CLI session isn't listening and the session launcher daemon is down, so nothing with Chrome " \
        "tools can pick this up. Start myjira-session-launcher.service, or paste the command into a CLI in this project."
    end

    def card_merge? = item.pr.present? && item.status == "review" && dependencies.empty?

    # Dependency chain with PRs, parent first, for "Merge both".
    def chain
      linked = ([item] + dependencies).select { |i| i.pr.present? }.uniq(&:key)
      linked.sort_by { |i| [i.n == item.parent ? 0 : 1, i.parent == item.n ? 2 : 1, i.n] }
    end

    def chain_merge? = item.pr.present? && chain.size > 1

    private

    def log_time
      at = item.log.last&.dig("at").to_i
      Time.zone.at(at / 1000.0) if at > 1_000_000_000_000 # epoch ms; anything smaller is not a real timestamp
    end

    def transcript_time
      path = transcript_path
      File.mtime(path) if path && File.exist?(path)
    rescue SystemCallError
      nil
    end
  end
end
