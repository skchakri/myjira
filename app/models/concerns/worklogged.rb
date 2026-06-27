# Mixed into any record whose lifecycle should show up on a live step timeline
# (SessionLaunch, Task, Conversation, …). `emit_worklog` fires one node through
# the Rails 8.1 structured event reporter, tagged "worklog" so only
# WorklogSubscriber picks it up — one emission path feeds both the host daemon's
# API PATCHes and the web flows. Guard the call site on the *transition* (e.g.
# `saved_change_to_status?`) so a re-PATCH of the same status can't dupe a node.
module Worklogged
  extend ActiveSupport::Concern

  included do
    # History, queried by the timeline view. Intentionally no `dependent:` — the
    # worklog outlives its subject (see WorklogEvent).
    has_many :worklog_events, as: :subject, inverse_of: :subject
  end

  # Emit a timeline node for this record. Rescue-wrapped so a worklog failure never
  # breaks the host action (mirrors Task#broadcast_board). The subject is passed by
  # reference — the subscriber runs synchronously in-process, so no serialisation.
  def emit_worklog(name, status:, label:, payload: {})
    Rails.event.tagged("worklog") do
      Rails.event.notify(name, subject: self, status: status, label: label.to_s, payload: payload)
    end
    nil
  rescue StandardError => e
    Rails.logger.warn("[worklog] #{name} emit failed: #{e.message}")
    nil
  end
end
