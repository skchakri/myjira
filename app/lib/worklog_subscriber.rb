# The single subscriber for Rails 8.1 `Rails.event` worklog events. Registered
# once in config/initializers/worklog.rb. For every event tagged "worklog" it
# persists a WorklogEvent row and live-appends one timeline node via Turbo Streams.
# Runs synchronously inside the emitting request/job — cheap at local volume — but
# the whole body is rescue-isolated so a worklog hiccup never breaks the caller.
class WorklogSubscriber
  def emit(event)
    return unless event.dig(:tags, :worklog)

    payload = event[:payload] || {}
    subject = payload[:subject]
    return unless subject

    record = WorklogEvent.record!(
      subject: subject,
      name: event[:name],
      status: payload[:status],
      label: payload[:label],
      payload: payload[:payload] || {},
      occurred_at: event_time(event[:timestamp])
    )

    broadcast(subject, record)
  rescue StandardError => e
    Rails.logger.warn("[worklog] subscriber failed: #{e.message}")
  end

  private

  # `Rails.event` stamps timestamps in nanoseconds; fall back to now if absent.
  def event_time(nanos)
    return Time.current unless nanos.is_a?(Numeric)
    Time.zone.at(nanos / 1_000_000_000.0)
  end

  # Append the new node to the eager <ul> the timeline frame renders. The previous
  # node (for the duration chip) is the latest one before this insert.
  def broadcast(subject, record)
    prev = subject.worklog_events.chronological.where.not(id: record.id).last
    Turbo::StreamsChannel.broadcast_append_to(
      [subject, :worklog],
      target: ActionView::RecordIdentifier.dom_id(subject, :worklog_list),
      partial: "worklog_events/event",
      locals: { event: record, prev: prev }
    )
  end
end
