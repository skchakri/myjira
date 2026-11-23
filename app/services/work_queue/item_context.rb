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
    def git = (@git ||= [StatusCache.git(item.key)]).first
    def dependencies = @dependencies ||= @store.dependencies(item)

    # Merge PR shows on the card only when nothing linked is still open.
    def card_merge? = item.pr.present? && item.status == "review" && dependencies.empty?

    # Dependency chain with PRs, parent first, for "Merge both".
    def chain
      linked = ([item] + dependencies).select { |i| i.pr.present? }.uniq(&:key)
      linked.sort_by { |i| [i.n == item.parent ? 0 : 1, i.parent == item.n ? 2 : 1, i.n] }
    end

    def chain_merge? = item.pr.present? && chain.size > 1
  end
end
