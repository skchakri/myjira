module WorkQueue
  # Pushes queue + transcript changes to open Work Queue pages as Turbo Streams.
  # In development/production Action Cable runs on the Redis adapter, so a
  # broadcast from the watcher process goes through Redis pub/sub to Puma.
  # A compact JSON event is also published on REDIS_CHANNEL for other consumers.
  module Broadcaster
    LIST_STREAM = "work_queue".freeze
    REDIS_CHANNEL = "myjira:work_queue:events".freeze

    module_function

    def item_stream(key) = "work_queue:item:#{key}"
    def log_stream(agent) = "work_queue:log:#{agent}"

    def project_changed(slug, items, transitions: [])
      Turbo::StreamsChannel.broadcast_replace_to(
        LIST_STREAM, target: "wq_project_#{slug}",
        partial: "work_queue/project", locals: { slug: slug, items: items }
      )
      items.each do |item|
        Turbo::StreamsChannel.broadcast_replace_to(
          item_stream(item.key), target: "wq_side",
          partial: "work_queue/side", locals: { item: item }
        )
        Turbo::StreamsChannel.broadcast_replace_to(
          item_stream(item.key), target: "wq_log_header",
          partial: "work_queue/log_header", locals: { item: item }
        )
      end
      transitions.each { |item, from| event(item, from) }
    end

    def event(item, from)
      Turbo::StreamsChannel.broadcast_append_to(
        LIST_STREAM, target: "wq_events",
        partial: "work_queue/event", locals: { item: item, from: from }
      )
      publish(type: "status", key: item.key, from: from, to: item.display_status, title: item.title)
    end

    def run_stream(key) = "work_queue:run:#{key}"

    # Server-run items (WorkQueue::Supervisor) stream here instead of a transcript.
    def run_entries(key, entries) = stream_entries(run_stream(key), entries)

    def log_entries(agent, entries) = stream_entries(log_stream(agent), entries)

    def stream_entries(stream, entries)
      return if entries.empty?

      entries.each do |e|
        if e.kind == "result"
          Turbo::StreamsChannel.broadcast_append_to(
            stream, target: "wq_out_#{e.tool_use_id}",
            partial: "work_queue/result", locals: { entry: e }
          )
        else
          Turbo::StreamsChannel.broadcast_append_to(
            stream, target: "wq_log_entries",
            partial: "work_queue/entry", locals: { entry: e }
          )
        end
      end
    end

    def log_note(agent, text)
      entry = Transcript::Entry.new(kind: "qa", body: text, at: Time.current.iso8601)
      log_entries(agent, [entry]) if agent.present?
    end

    def publish(payload)
      redis.publish(REDIS_CHANNEL, payload.to_json)
    rescue Redis::BaseError
      nil
    end

    def redis
      @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
    end
  end
end
