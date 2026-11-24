module WorkQueue
  # What "Run in Chrome" did for an item, kept in its RunState hash so the detail
  # pane can show it: the SessionLaunch spawned for it (id under FIELD), or when
  # the browser step was handed to the listening CLI (epoch seconds under SENT).
  # A reverse key (launch id → item key) lets a launch status change refresh the
  # open pane, the same semantics as BrowserTask#active_chrome_launch.
  module ChromeRun
    FIELD = "chrome_launch".freeze
    SENT = "chrome_sent_at".freeze
    WINDOW = BrowserTask::CHROME_RUN_WINDOW

    module_function

    def dom_id(item) = "wq_chrome_#{item.slug}_#{item.n}"

    def remember(item, launch)
      RunState.set(item.key, FIELD => launch.id)
      RunState.redis.set(reverse_key(launch.id), item.key, ex: WINDOW.to_i * 2)
    end

    def sent!(item) = RunState.set(item.key, SENT => Time.current.to_i)

    # The launch still starting, or launched recently enough to count as working the item.
    def active_launch(run)
      return nil if run[FIELD].blank?

      launch = SessionLaunch.find_by(id: run[FIELD])
      return nil unless launch
      return launch if %w[pending launching].include?(launch.status)

      launch if launch.status == "launched" && launch.launched_at && launch.launched_at >= WINDOW.ago
    end

    # When the step last went to the listening CLI, while that is still recent.
    def sent_at(run)
      at = run[SENT].to_i
      Time.zone.at(at) if at.positive? && at >= WINDOW.ago.to_i
    end

    # A launch changed status (the daemon claimed, spawned or failed it): redraw
    # the control on the item's open detail pane. Never raises into the caller.
    def launch_changed(launch)
      key = RunState.redis.get(reverse_key(launch.id))
      item = key && Store.new.find(key)
      return unless item

      Turbo::StreamsChannel.broadcast_replace_to(
        Broadcaster.item_stream(item.key), target: dom_id(item), partial: "work_queue/chrome_run",
        locals: { item: item, context: ItemContext.new(item, store: Store.new) }
      )
    rescue StandardError => e
      Rails.logger.warn("[work-queue] chrome launch refresh failed: #{e.class}: #{e.message}")
    end

    def reverse_key(id) = "#{RunState::PREFIX}:chrome_launch:#{id}"
  end
end
