module WorkQueue
  # Everything a card / log header needs about an item beyond the queue JSON:
  # transcript path, worktree + git status, PR status, open dependencies.
  class ItemContext
    attr_reader :item

    def initialize(item, store:, prs: PullRequests.new)
      @item = item
      @store = store
      @prs = prs
    end

    def server_run? = @server_run.nil? ? (@server_run = RunState.server_run?(item.key)) : @server_run
    def run = @run ||= RunState.get(item.key)
    def phases = @phases ||= RunState.phases(item.key)

    def transcript_path = @transcript_path ||= Transcript.path_for(item)
    def worktree = @worktree ||= run["worktree"].presence || Transcript.cwd_for(transcript_path)
    # Both read the background-refreshed StatusCache; rendering never runs git/gh.
    def pr_status = (@pr_status ||= [item.pr && item.open? ? StatusCache.pr(item.pr) : nil]).first
    def delivery = (@delivery ||= [item.pr ? StatusCache.delivery(item.pr) : nil]).first
    def git = (@git ||= [StatusCache.git(item.key)]).first
    def dependencies = @dependencies ||= @store.dependencies(item)
    def flow = @flow ||= Flow.new(item, self)
    def project_items = @project_items ||= @store.items_for(item.slug)

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
  end
end
