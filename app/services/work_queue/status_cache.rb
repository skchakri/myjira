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
    #
    # Most sweeps find nothing new, so two shortcuts (per process; `force` skips both):
    # git is recomputed only when the worktree's refs moved (GitInfo.signature is one
    # git call against ~60 for a full compute), and a PR is re-read from GitHub only
    # when its interval is up.
    PR_EVERY = { open: 60, done: 180 }.freeze
    MEMO = { git: {}, pr: {} } # rubocop:disable Style/MutableConstant

    def refresh(item, store:, prs: PullRequests.new, delivery: Delivery.new, force: false, now: Time.current)
      pr_json = item.pr.present? ? pr_json(item, prs, delivery, force, now) : nil
      git_json = item.open? ? git_json(item, store, force) : ""
      sig = [git_json, pr_json].join
      redis.getset("#{git_key(item.key)}:sig", sig) != sig
    end

    def pr_json(item, prs, delivery, force, now)
      memo = MEMO[:pr][item.pr]
      return memo[1] if !force && memo && now - memo[0] < PR_EVERY[item.open? ? :open : :done]

      st = prs.fetch(item.pr)
      json = (st&.to_h || {}).to_json
      redis.set(pr_key(item.pr), json, ex: TTL)
      json += delivery_json(item.pr, st, delivery)
      MEMO[:pr][item.pr] = [now, json]
      json
    end

    # The PR's delivery state as stored. When GitHub could not be asked (outage, rate limit)
    # nothing is written: the last known state stays, instead of reading "not live".
    def delivery_json(pr, status, delivery)
      json = (delivery.compute(status)&.to_h || {}).to_json
      redis.set(delivery_key(pr), json, ex: TTL)
      json
    rescue Delivery::Unavailable
      redis.get(delivery_key(pr)).to_s
    end

    def git_json(item, store, force)
      worktree = ItemContext.new(item, store: store).worktree
      base = pr(item.pr)&.base
      stamp = [worktree, base, GitInfo.signature(worktree)]
      memo = MEMO[:git][item.key]
      if !force && memo && stamp.last && memo[0] == stamp
        redis.expire(git_key(item.key), TTL)
        return memo[1]
      end

      json = (GitInfo.compute(worktree, pr_base: base)&.to_h || {}).to_json
      redis.set(git_key(item.key), json, ex: TTL)
      MEMO[:git][item.key] = [stamp, json]
      json
    end

    # Done items whose PR may still be on its way to production.
    def delivering?(item)
      item.status == "done" && item.pr.present? && !delivery(item.pr)&.live? &&
        item.updated_at.present? && item.updated_at > 14.days.ago
    end
  end
end
