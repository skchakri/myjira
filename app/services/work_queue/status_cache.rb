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
    def delivery_key(pr) = "#{RunState::PREFIX}:delivery:#{pr}"

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

    def delivery(pr)
      return if pr.blank?

      raw = redis.get(delivery_key(pr)) or return
      h = JSON.parse(raw)
      h.empty? ? nil : Delivery::State.new(**h.symbolize_keys.slice(*Delivery::State.members))
    rescue JSON::ParserError, Redis::BaseError
      nil
    end

    # Recompute one item's status; true when it differs from what was cached.
    # Done items only refresh PR + delivery (their worktree is gone).
    def refresh(item, store:, prs: PullRequests.new, delivery: Delivery.new)
      pr_json = nil
      if item.pr.present?
        st = prs.fetch(item.pr)
        pr_json = (st&.to_h || {}).to_json
        redis.set(pr_key(item.pr), pr_json, ex: TTL)
        pr_json += (delivery.compute(st)&.to_h || {}).to_json.tap { |d| redis.set(delivery_key(item.pr), d, ex: TTL) }
      end
      git_json = ""
      if item.open?
        ctx = ItemContext.new(item, store: store)
        info = GitInfo.compute(ctx.worktree, pr_base: pr(item.pr)&.base)
        git_json = (info&.to_h || {}).to_json
        redis.set(git_key(item.key), git_json, ex: TTL)
      end
      sig = [git_json, pr_json].join
      redis.getset("#{git_key(item.key)}:sig", sig) != sig
    end

    # Done items whose PR may still be on its way to production.
    def delivering?(item)
      item.status == "done" && item.pr.present? && !delivery(item.pr)&.live? &&
        item.updated_at.present? && item.updated_at > 14.days.ago
    end
  end
end
