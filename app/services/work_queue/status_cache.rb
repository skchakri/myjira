module WorkQueue
  # Git + PR status for cards, kept in Redis so the page never shells out to
  # git/gh while rendering. The watcher (bin/work-queue-watch) refreshes it in
  # the background and pushes a card replace when an item's status changes.
  # Shared between processes (Puma + watcher), so Redis rather than Rails.cache.
  module StatusCache
    TTL = 1.day.to_i

    module_function

    def redis = RunState.redis
    def git_key(item_key) = "#{RunState::PREFIX}:git:#{item_key}"
    def pr_key(pr) = "#{RunState::PREFIX}:pr:#{pr}"

    def git(item_key)
      raw = redis.get(git_key(item_key)) or return
      h = JSON.parse(raw)
      h.empty? ? nil : GitInfo::Info.new(**h.symbolize_keys.slice(*GitInfo::Info.members))
    rescue JSON::ParserError, Redis::BaseError
      nil
    end

    def pr(pr)
      return if pr.blank?

      raw = redis.get(pr_key(pr)) or return
      h = JSON.parse(raw)
      h.empty? ? nil : PullRequests::Status.new(**h.symbolize_keys.slice(*PullRequests::Status.members))
    rescue JSON::ParserError, Redis::BaseError
      nil
    end

    # Recompute one item's status; true when it differs from what was cached.
    def refresh(item, store:, prs: PullRequests.new)
      pr_json = nil
      if item.pr.present?
        st = prs.fetch(item.pr)
        pr_json = (st&.to_h || {}).to_json
        redis.set(pr_key(item.pr), pr_json, ex: TTL)
      end
      ctx = ItemContext.new(item, store: store)
      info = GitInfo.compute(ctx.worktree, pr_base: pr(item.pr)&.base)
      git_json = (info&.to_h || {}).to_json
      redis.set(git_key(item.key), git_json, ex: TTL)
      sig = [git_json, pr_json].join
      redis.getset("#{git_key(item.key)}:sig", sig) != sig
    end
  end
end
