module WorkQueue
  # Server-side writer for ~/.claude/queues/<slug>.json, used when no CLI
  # session owns the queue. Same schema as the work-queue mod (types/Item):
  # only the mod's own fields are written; runner metadata lives in Redis
  # (WorkQueue::RunState). Every write is read-modify-write under an exclusive
  # flock on "<file>.lock", then an atomic rename, so a CLI mod that opens later
  # simply sees a newer mtime and reloads. (The mod itself does not take the
  # lock; the atomic rename keeps its reads whole.)
  class QueueWriter
    STATUSES = %w[triage queued running blocked review done merged dropped].freeze

    def initialize(dir: Store.dir)
      @dir = Pathname(dir)
    end

    def path(slug)
      raise ArgumentError, "bad slug" unless slug.to_s.match?(/\A[A-Za-z0-9-]+\z/)

      @dir.join("#{slug}.json")
    end

    def add(slug, title:, description: "", parent: nil, session: nil, by: nil, priority: nil)
      item = nil
      transaction(slug) do |items|
        now = now_ms
        item = { "n" => (items.map { |i| i["n"].to_i }.max || 0) + 1, "title" => title.to_s.strip.truncate(120),
                 "description" => description.to_s, "status" => "triage", "questions" => [],
                 "log" => [{ "at" => now, "text" => "Added from myjira" }], "createdAt" => now, "updatedAt" => now }
        item["session"] = session if session
        # Follow-ups never wait for approval: they start by themselves and ship in the parent's PR.
        item["parent"] = parent.to_i if parent
        follow = { "by" => by, "priority" => priority }.compact
        item["followUp"] = follow if follow.any?
        items << item
      end
      item
    end

    # Yields the item hash for in-place changes; stamps updatedAt and logs status moves.
    def update(slug, n, log: nil)
      transaction(slug) do |items|
        item = items.find { |i| i["n"].to_i == n.to_i } or raise ArgumentError, "no item ##{n}"
        before = item["status"]
        yield item if block_given?
        raise ArgumentError, "bad status #{item['status']}" unless STATUSES.include?(item["status"])

        at = now_ms
        item["log"] = Array(item["log"])
        item["log"] << { "at" => at, "text" => log } if log
        item["log"] << { "at" => at, "text" => "→ #{item['status']}" } if before != item["status"]
        item["updatedAt"] = at
      end
    end

    # Merge keys into the item's followUp record (nil values remove a key).
    def follow_up(slug, n, attrs, log: nil, &block)
      update(slug, n, log: log) do |i|
        record = (i["followUp"].is_a?(Hash) ? i["followUp"] : {}).merge(attrs.stringify_keys).compact
        record.any? ? i["followUp"] = record : i.delete("followUp")
        block&.call(i)
      end
    end

    # Errand fields ("kind": "yours", "due", "snoozedUntil", "yoursAt"): nil removes a key.
    def errand(slug, n, attrs, log: nil, &block)
      update(slug, n, log: log) do |i|
        attrs.stringify_keys.each { |k, v| v.nil? ? i.delete(k) : i[k] = v }
        block&.call(i)
      end
    end

    def set_status(slug, n, status, log: nil) = update(slug, n, log: log) { |i| i["status"] = status }

    def ask(slug, n, questions)
      update(slug, n, log: "Asked #{questions.size} question(s)") do |i|
        i["questions"] = Array(i["questions"]) + questions.map { |q| { "q" => q[:q] || q["q"], "at" => now_ms, "options" => Array(q[:options] || q["options"]).first(4) } }
        i["status"] = "blocked"
      end
    end

    def answer(slug, n, index, text)
      update(slug, n, log: "Answered from myjira: #{text.truncate(80)}") do |i|
        qs = Array(i["questions"])
        k = qs[index] && !qs[index].key?("a") ? index : qs.index { |q| !q.key?("a") }
        qs[k]["a"] = text if k
        i.delete("awaitingApproval")
        i["status"] = "running" if i["status"] == "blocked" && qs.all? { |q| q.key?("a") }
      end
    end

    def merge_into(slug, target, others)
      transaction(slug) do |items|
        tgt = items.find { |i| i["n"] == target } or raise ArgumentError, "no item ##{target}"
        others.each do |n|
          src = items.find { |i| i["n"] == n } or next
          src["status"] = "merged"
          src["mergedInto"] = target
          src["log"] = Array(src["log"]) << { "at" => now_ms, "text" => "Merged into ##{target}" }
          src["updatedAt"] = now_ms
          tgt["description"] = "#{tgt['description']}\n\nFolded in ##{n}: #{src['title']}\n#{src['description']}".strip
        end
        tgt["updatedAt"] = now_ms
      end
    end

    private

    def transaction(slug)
      file = path(slug)
      FileUtils.mkdir_p(@dir)
      File.open("#{file}.lock", File::RDWR | File::CREAT, 0o644) do |lock|
        match_owner(lock.path)
        lock.flock(File::LOCK_EX)
        data = file.exist? ? JSON.parse(File.read(file)) : { "items" => [] }
        items = data.is_a?(Hash) ? (data["items"] ||= []) : data
        yield items
        tmp = "#{file}.tmp-#{Process.pid}"
        File.write(tmp, "#{JSON.pretty_generate(data.is_a?(Hash) ? data : { 'items' => items })}\n")
        match_owner(tmp)
        File.rename(tmp, file)
      end
    end

    # In the pyr-myjira container we run as root on /home/kalyan files; keep
    # the queue owned by whoever owns the directory so the CLI can still write it.
    def match_owner(path)
      return unless Process.uid.zero?

      st = File.stat(@dir)
      File.chown(st.uid, st.gid, path)
    rescue SystemCallError
      nil
    end

    def now_ms = (Time.now.to_f * 1000).to_i
  end
end
