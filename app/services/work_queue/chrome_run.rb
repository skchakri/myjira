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
    # Seconds one "Run in Chrome" click holds the item, so a near-simultaneous
    # second click can't pass the duplicate check before the first has queued.
    LOCK_TTL = 5
    REASON_LENGTH = 120
    NO_REASON = "the session launcher could not start Claude".freeze

    module_function

    def dom_id(item) = "wq_chrome_#{item.slug}_#{item.n}"

    def remember(item, launch)
      RunState.set(item.key, FIELD => launch.id)
      RunState.redis.set(reverse_key(launch.id), item.key, ex: WINDOW.to_i * 2)
    end

    # The step went to the listening CLI instead: forget any earlier (failed) launch.
    def sent!(item)
      RunState.del_fields(item.key, FIELD)
      RunState.set(item.key, SENT => Time.current.to_i)
    end

    # Runs the block while holding the item's short Redis lock (SET NX EX) and
    # returns its value; returns nil without running it when another request holds it.
    def exclusive(item)
      key = lock_key(item.key)
      token = SecureRandom.hex(8)
      return nil unless RunState.redis.set(key, token, nx: true, ex: LOCK_TTL)

      begin
        yield
      ensure
        RunState.redis.del(key) if RunState.redis.get(key) == token
      end
    end

    # The launch still starting, or launched recently enough to count as working the item.
    # A launch tied to the item (work_item_key) counts for as long as it is live:
    # the daemon flips it to finished/closed when its tmux window goes away, so
    # there is no time window to age out of while the session is still open.
    def active_launch(run, key: nil)
      if key && (live = SessionLaunch.live.where(chrome: true, work_item_key: key).order(created_at: :desc).first)
        return live
      end
      return nil if run[FIELD].blank?

      launch = SessionLaunch.find_by(id: run[FIELD])
      return nil unless launch
      return launch if %w[pending launching].include?(launch.status)
      return nil if launch.work_item_key.present? # tied launches are judged by status alone, above

      launch if launch.status == "launched" && launch.launched_at && launch.launched_at >= WINDOW.ago
    end

    # The item's last launch when it ended failed; nil once a new launch is queued
    # (remember overwrites FIELD) or the step went to the CLI instead.
    def failed_launch(run)
      return nil if run[FIELD].blank?

      launch = SessionLaunch.find_by(id: run[FIELD])
      launch if launch&.status == "failed"
    end

    # Short, single-line reason for the "Launch failed" hint and the item log.
    def failure_reason(launch) = (launch.error.to_s.squish.presence || NO_REASON).truncate(REASON_LENGTH)

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

      note_failure(item, launch) if launch.status == "failed"
      Turbo::StreamsChannel.broadcast_replace_to(
        Broadcaster.item_stream(item.key), target: dom_id(item), partial: "work_queue/chrome_run",
        locals: { item: item, context: ItemContext.new(item, store: Store.new) }
      )
    rescue StandardError => e
      Rails.logger.warn("[work-queue] chrome launch refresh failed: #{e.class}: #{e.message}")
    end

    # One item-log note per failed launch, however often its status is re-sent.
    def note_failure(item, launch)
      return unless RunState.redis.set(noted_key(launch.id), "1", nx: true, ex: WINDOW.to_i * 2)

      Broadcaster.item_note(item, "Run in Chrome: launch failed: #{failure_reason(launch)}")
    end

    def reverse_key(id) = "#{RunState::PREFIX}:chrome_launch:#{id}"
    def noted_key(id) = "#{RunState::PREFIX}:chrome_failed:#{id}"
    def lock_key(item_key) = "#{RunState::PREFIX}:chrome_lock:#{item_key}"
  end
end
