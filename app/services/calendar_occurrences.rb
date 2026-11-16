# Expands every calendar source into concrete occurrences inside a time window,
# in the host's display zone. Cron-backed jobs are expanded with Fugit; jobs that
# only know their next/last fire (systemd timers, run-once routines) contribute
# those instants. Anything firing more than once a day collapses to one chip per
# day ("every 10m · ×144") so a sysstat-style job can't flood the month grid.
class CalendarOccurrences
  Occurrence = Struct.new(:key, :source, :title, :at, :per_day, :item, :past, keyword_init: true)

  MAX_PER_JOB = 400

  attr_reader :zone, :from, :to

  def initialize(from:, to:, zone: CalendarJob.display_zone)
    @zone = zone
    @from = from.in_time_zone(zone)
    @to   = to.in_time_zone(zone)
  end

  def items
    @items ||= CalendarJob.visible.includes(:project).to_a +
               AgentSchedule.includes(:project, :agent).to_a
  end

  # Suggestions have never run, so they only show from now on.
  def all
    @all ||= items.flat_map { |item| for_item(item) }
                  .reject { |o| o.past && o.source == "suggested" }
                  .sort_by(&:at)
  end

  def by_day
    all.group_by { |o| o.at.to_date }
  end

  # Within a day, the user's own work leads and OS housekeeping sinks: myjira
  # schedules, Claude jobs and suggestions, then the user's crontab, then root
  # crontabs and systemd timers; "every Nm" chips go last within each tier.
  SOURCE_RANK = %w[myjira_schedule claude_cron claude_routine suggested system_cron systemd_timer].freeze

  def self.day_order(occ)
    rank = SOURCE_RANK.index(occ.source) || SOURCE_RANK.size
    rank += 0.5 if occ.source == "system_cron" && occ.item.meta["user"].present? # root /etc crontabs
    [rank, occ.per_day ? 1 : 0, occ.at]
  end

  def self.source_of(item)
    item.is_a?(AgentSchedule) ? "myjira_schedule" : item.source
  end

  def self.title_of(item)
    return item.title unless item.is_a?(AgentSchedule)
    item.agent ? "#{item.agent.name} · #{item.project.name}" : "#{item.prompt.to_s.squish.truncate(60)} · #{item.project.name}"
  end

  private

  def for_item(item)
    cron = item.cron.presence && Fugit.parse_cron(item.cron)
    cron ? from_cron(item, cron) : from_instants(item)
  end

  def build(item, at, per_day: nil)
    Occurrence.new(key: "#{item.class.name}-#{item.id}-#{at.to_i}",
                   source: self.class.source_of(item), title: self.class.title_of(item),
                   at: at.in_time_zone(zone), per_day: per_day, item: item, past: at < Time.current)
  end

  def from_cron(item, cron)
    t1 = cron.next_time(from.to_time).to_t
    t2 = cron.next_time(t1 + 1).to_t
    gap = t2 - t1
    return sub_daily(item, cron, gap) if gap < 1.day

    out = []
    t = t1
    while t <= to && out.size < MAX_PER_JOB
      out << build(item, t)
      t = cron.next_time(t + 1).to_t
    end
    out
  end

  # One chip per day, at that day's first fire, carrying the per-day count.
  def sub_daily(item, cron, gap)
    per_day = (1.day / gap).round
    (from.to_date..to.to_date).filter_map do |d|
      first = cron.next_time(zone.local(d.year, d.month, d.day).to_time - 1).to_t
      build(item, first, per_day: per_day) if first.in_time_zone(zone).to_date == d
    end
  end

  def from_instants(item)
    [item.try(:last_run_at), item.try(:next_run_at)].compact.uniq
      .select { |t| t >= from && t <= to }
      .map { |t| build(item, t) }
  end
end
