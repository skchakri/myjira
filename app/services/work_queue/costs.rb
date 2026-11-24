module WorkQueue
  # What the server runner has spent, from the per-phase cost records.
  #
  # RunState.record_phase keeps running totals in two small Redis hashes per
  # project (per item, per day) plus one global hash (per phase and model), so a
  # page reads one hash per project instead of one list per item. Only server-run
  # phases are recorded; work done in a CLI session has no cost here.
  #
  #   costs = Costs.project(slug)   # costs.item(7), costs.tree(item, descendants), costs.total
  #   Costs.overview                # everything the cost page shows
  #   Costs.rebuild!                # recount the totals from the phase records
  module Costs
    DAYS = 14

    # One project's per-item totals.
    Project = Struct.new(:slug, :items) do
      def item(n) = items[n.to_i].to_f
      def total = items.values.sum
      # An item plus everything below it (descendants: Store::Item list).
      def tree(item, descendants = []) = ([item] + descendants).uniq(&:n).sum { |i| self.item(i.n) }
    end

    Overview = Struct.new(:total, :days, :projects, :mix, :top, keyword_init: true)

    module_function

    def redis = RunState.redis
    def items_key(slug) = "#{RunState::PREFIX}:cost:items:#{slug}"
    def days_key(slug) = "#{RunState::PREFIX}:cost:days:#{slug}"
    def mix_key = "#{RunState::PREFIX}:cost:mix"
    def slugs_key = "#{RunState::PREFIX}:cost:slugs"

    # Called for every recorded phase.
    def add(key, cost, phase:, model:, day: Time.zone.today)
      cost = cost.to_f
      slug, n = key.to_s.split(":", 2)
      return unless cost.positive? && slug.present? && n.present?

      redis.pipelined do |p|
        p.hincrbyfloat(items_key(slug), n, cost)
        p.hincrbyfloat(days_key(slug), day.iso8601, cost)
        p.hincrbyfloat(mix_key, "#{phase}|#{model}", cost)
        p.sadd(slugs_key, slug)
      end
    end

    def project(slug)
      Project.new(slug, redis.hgetall(items_key(slug)).to_h { |n, c| [n.to_i, c.to_f] })
    rescue Redis::BaseError
      Project.new(slug, {})
    end

    def today(slug) = redis.hget(days_key(slug), Time.zone.today.iso8601).to_f

    def slugs = redis.smembers(slugs_key).sort

    def overview(days: DAYS)
      list = slugs
      replies = redis.pipelined do |p|
        list.each { |s| p.hgetall(items_key(s)) }
        list.each { |s| p.hgetall(days_key(s)) }
      end
      items = replies.first(list.size)
      by_day = replies.last(list.size)
      range = ((Time.zone.today - (days - 1))..Time.zone.today).to_a
      today = Time.zone.today.iso8601
      projects = list.each_with_index.map do |slug, i|
        { slug: slug, total: items[i].values.sum(&:to_f), today: by_day[i][today].to_f,
          recent: range.sum { |d| by_day[i][d.iso8601].to_f }, tasks: items[i].size }
      end
      top = list.each_with_index.flat_map { |slug, i| items[i].map { |n, c| { slug: slug, n: n.to_i, cost: c.to_f } } }
      mix = redis.hgetall(mix_key).map do |k, c|
        phase, model = k.split("|", 2)
        { phase: phase, model: model, cost: c.to_f }
      end
      Overview.new(total: projects.sum { |row| row[:total] }, projects: projects.sort_by { |row| -row[:total] },
                   mix: mix.sort_by { |row| -row[:cost] }, top: top.sort_by { |row| -row[:cost] }.first(10),
                   days: range.map { |d| [d, by_day.sum { |h| h[d.iso8601].to_f }] })
    end

    # Recount every total from the phase records (run once after deploying, or to repair).
    def rebuild!
      old = redis.scan_each(match: "#{RunState::PREFIX}:cost:*").to_a
      redis.del(*old) if old.any?
      rows = 0
      redis.scan_each(match: "#{RunState::PREFIX}:phases:*") do |list|
        key = list.delete_prefix("#{RunState::PREFIX}:phases:")
        redis.lrange(list, 0, -1).each do |raw|
          row = JSON.parse(raw)
          day = (Time.zone.parse(row["at"].to_s) || Time.current).to_date
          add(key, row["cost_usd"], phase: row["phase"], model: row["model"], day: day)
          rows += 1
        rescue JSON::ParserError, ArgumentError
          next
        end
      end
      rows
    end
  end
end
