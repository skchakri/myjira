# The Calendar: a month grid (agenda list on small screens) of every recurring
# job we know about — myjira AgentSchedules, Claude crons/routines, system cron,
# systemd timers — plus suggested tasks mined from captured Claude sessions.
# ?month=YYYY-MM picks the month; ?hide=src,src remembers unticked sources.
class CalendarController < ApplicationController
  def show
    @zone  = CalendarJob.display_zone
    today  = Time.current.in_time_zone(@zone).to_date
    @month = parse_month(params[:month]) || today.beginning_of_month
    @today = today
    @grid_start = @month.beginning_of_week(:monday)
    @grid_end   = @month.end_of_month.end_of_week(:monday)

    @hidden = params[:hide].to_s.split(",") & CalendarJob::SOURCES.keys
    occ = CalendarOccurrences.new(from: @zone.local(@grid_start.year, @grid_start.month, @grid_start.day),
                                  to: @zone.local(@grid_end.year, @grid_end.month, @grid_end.day).end_of_day,
                                  zone: @zone)
    @source_counts = occ.items.group_by { |i| CalendarOccurrences.source_of(i) }.transform_values(&:size)
    visible = occ.all.reject { |o| @hidden.include?(o.source) }
    @by_day = visible.group_by { |o| o.at.to_date }
                     .transform_values { |day| day.sort_by { |o| CalendarOccurrences.day_order(o) } }
    @upcoming = visible.select { |o| o.at >= Time.current && o.per_day.nil? }.first(12)
    @suggestions = CalendarJob.visible.suggested.includes(:project, :agent_schedule).order(:title)
    @last_synced = CalendarJob.where(source: CalendarJob::SYNCED_SOURCES).maximum(:synced_at)
  end

  private

  def parse_month(raw)
    Date.strptime(raw.to_s, "%Y-%m") if raw.to_s.match?(/\A\d{4}-\d{2}\z/)
  rescue Date::Error
    nil
  end
end
