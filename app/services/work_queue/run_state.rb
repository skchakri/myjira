module WorkQueue
  # Runner state in Redis (shared between Puma and the runner supervisor):
  # per-item run metadata, per-phase cost records, per-project settings
  # (default model/effort, always-allowed tools) and the editable routing table.
  module RunState
    PREFIX = (Rails.env.test? ? "myjira:wq:test" : "myjira:wq").freeze
    JOBS = "#{PREFIX}:jobs".freeze

    module_function

    def redis = Broadcaster.redis

    def get(key) = redis.hgetall("#{PREFIX}:run:#{key}")
    def set(key, attrs)
      redis.hset("#{PREFIX}:run:#{key}", attrs.transform_values(&:to_s)) if attrs.any?
    end
    def del_fields(key, *fields) = redis.hdel("#{PREFIX}:run:#{key}", fields)

    def record_phase(key, row)
      redis.rpush("#{PREFIX}:phases:#{key}", row.merge(at: Time.current.iso8601).to_json)
      Costs.add(key, row[:cost_usd] || row["cost_usd"], phase: row[:phase] || row["phase"], model: row[:model] || row["model"])
    end

    def phases(key) = redis.lrange("#{PREFIX}:phases:#{key}", 0, -1).map { |r| JSON.parse(r) }

    def project(slug)
      raw = redis.get("#{PREFIX}:project:#{slug}")
      { "always_allow" => [], "model" => nil, "effort" => nil, "daily_budget" => nil }.merge(raw ? JSON.parse(raw) : {})
    end

    DEFAULT_REVIEW_LIMIT = 8

    # How many of a project's tasks may wait on the person before agent-filed follow-ups
    # are held instead of started. nil = no limit (saved blank); unset = the default.
    def review_limit(slug)
      settings = project(slug)
      return DEFAULT_REVIEW_LIMIT unless settings.key?("review_limit")

      settings["review_limit"].to_i.positive? ? settings["review_limit"].to_i : nil
    end

    # Follow-up limits only apply to follow-ups filed after the feature first ran,
    # so a deploy never holds the existing backlog.
    def followup_limits_since
      key = "#{PREFIX}:followup_limits_since"
      redis.set(key, Time.current.to_f, nx: true)
      Time.zone.at(redis.get(key).to_f)
    end

    def save_project(slug, attrs) = redis.set("#{PREFIX}:project:#{slug}", project(slug).merge(attrs.stringify_keys).to_json)

    def routing
      raw = redis.get("#{PREFIX}:routing")
      Router::DEFAULTS.deep_merge(raw ? JSON.parse(raw) : {})
    end

    def save_routing(table) = redis.set("#{PREFIX}:routing", table.to_json)

    # Daily budget in dollars for a project's server runs (nil = none). Items that
    # arrive after it is spent are held, and released when the project is under it again.
    def daily_budget(slug) = project(slug)["daily_budget"].to_f.then { |b| b.positive? ? b : nil }
    def over_budget?(slug) = (b = daily_budget(slug)) ? Costs.today(slug) >= b : false
    def hold(slug, key) = redis.sadd("#{PREFIX}:held:#{slug}", key)
    def held(slug) = redis.smembers("#{PREFIX}:held:#{slug}")
    def release(slug, key) = redis.srem("#{PREFIX}:held:#{slug}", key)
    def held_slugs = redis.scan_each(match: "#{PREFIX}:held:*").map { |k| k.delete_prefix("#{PREFIX}:held:") }

    # Commands for the supervisor: start / answer / continue / stop / allow.
    def enqueue(action, key, **extra) = redis.rpush(JOBS, extra.merge(action: action, key: key).to_json)

    # Items linked by a pasted [wq-ref …] (both directions).
    def relate(a, b)
      return if a == b

      redis.sadd("#{PREFIX}:related:#{a}", b)
      redis.sadd("#{PREFIX}:related:#{b}", a)
    end

    def related(key) = redis.smembers("#{PREFIX}:related:#{key}")

    def runner
      raw = redis.get("#{PREFIX}:runner")
      raw ? JSON.parse(raw) : nil
    end

    def server_run?(key) = redis.hexists("#{PREFIX}:run:#{key}", "mode")

    # Persisted stream for replay when the page opens mid-run.
    def append_stream(key, event) = redis.rpush("#{PREFIX}:stream:#{key}", event.to_json).tap { redis.ltrim("#{PREFIX}:stream:#{key}", -5000, -1) }
    def stream(key) = redis.lrange("#{PREFIX}:stream:#{key}", 0, -1).map { |r| JSON.parse(r) }
  end
end
