module CalendarHelper
  # Calendar URL with one source's visibility flipped, keeping the month.
  def calendar_toggle_path(source, month, hidden)
    hide = hidden.include?(source) ? hidden - [source] : hidden + [source]
    calendar_path(month: month.strftime("%Y-%m"), hide: hide.join(",").presence)
  end

  def calendar_item_link_path(item)
    calendar_item_path(type: item.is_a?(AgentSchedule) ? "schedule" : "job", id: item.id)
  end

  def calendar_source_glyph(source)
    content_tag :span, CalendarJob::SOURCES.dig(source, :glyph), class: "cal-glyph cal-src-#{source}", aria: { hidden: true }
  end

  # "09:00" — or "every 10m" for a job collapsed to one chip per day.
  def calendar_occurrence_time(occ)
    return occ.at.strftime("%H:%M") unless occ.per_day
    gap = 1440 / occ.per_day
    gap >= 60 ? "every #{gap / 60}h" : "every #{gap}m"
  end

  def calendar_item_disabled?(item)
    item.respond_to?(:enabled?) && !item.enabled?
  end
end
