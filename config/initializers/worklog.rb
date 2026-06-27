# Wire the worklog timeline onto the Rails 8.1 structured event reporter. One
# subscriber, registered after the app initializes (so WorklogSubscriber and the
# models it touches are autoloadable). It only acts on events tagged "worklog"
# (see Worklogged#emit_worklog), so it's inert for any other Rails.event traffic.
Rails.application.config.after_initialize do
  Rails.event.subscribe(WorklogSubscriber.new)
end
