# Shared wait loop for the API long-poll endpoints (myjira-listen command inbox,
# browser-task threads).
#
# A long-poll used to `sleep` inside the request for up to 30s while holding
# its Puma thread, its DB connection and — in development — the Rails executor
# share lock. When a file changed, the next request asked the reloader for the
# exclusive unload lock, which blocks every *new* request until *all* running
# requests finish. With clients re-polling continuously and only a few Puma
# threads, the server sat behind that lock and served nothing.
#
# So the wait loop:
#   * hands its DB connection back to the pool between checks, and
#   * returns early as soon as a code reload is pending, so the reloader gets
#     its lock within ~1s. The client just sees an empty poll and re-polls.
module LongPoll
  POLL_INTERVAL = 1.0

  private

  # Waits up to `wait` seconds until the block returns truthy. Returns the
  # block's last value.
  def long_poll(wait, interval: POLL_INTERVAL)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
    loop do
      result = yield
      return result if result
      return result if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      return result if reload_pending?

      ActiveRecord::Base.connection_handler.clear_active_connections!
      sleep interval
    end
  end

  def reload_pending?
    Rails.application.config.enable_reloading && Rails.application.reloader.check!
  end
end
