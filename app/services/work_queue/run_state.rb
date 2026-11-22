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
    end

    def phases(key) = redis.lrange("#{PREFIX}:phases:#{key}", 0, -1).map { |r| JSON.parse(r) }

    def project(slug)
      raw = redis.get("#{PREFIX}:project:#{slug}")
      { "always_allow" => [], "model" => nil, "effort" => nil }.merge(raw ? JSON.parse(raw) : {})
    end

    def save_project(slug, attrs) = redis.set("#{PREFIX}:project:#{slug}", project(slug).merge(attrs.stringify_keys).to_json)

    def routing
      raw = redis.get("#{PREFIX}:routing")
      Router::DEFAULTS.deep_merge(raw ? JSON.parse(raw) : {})
    end

    def save_routing(table) = redis.set("#{PREFIX}:routing", table.to_json)

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
