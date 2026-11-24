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

    # The project's shape changed (an item was added, removed, moved under another
    # parent, or reopened): redraw its whole block. Only the items that changed, and
    # the parents above them, get a fresh detail header.
    def project_changed(slug, items, changed: items, transitions: [])
      Turbo::StreamsChannel.broadcast_replace_to(
        LIST_STREAM, target: "wq_project_#{slug}",
        partial: "work_queue/project", locals: { slug: slug, items: items }
      )
      with_ancestors(changed, items).each { |item| log_header(item) }
      transitions.each { |item, from| event(item, from) }
    end

    # Items changed but the tree did not: redraw their cards (and their parents'),
    # the project's title-bar numbers, and announce any status moves.
    def items_changed(changed, transitions: [])
      cards_changed(changed)
      transitions.each { |item, from| event(item, from) }
    end

    # Replace just these cards (status/git/PR change) instead of the whole project.
    # Their parents are re-rendered too: a parent's progress rolls up its child steps.
    def cards_changed(items, counts: true)
      store = Store.new
      items.group_by(&:slug).each do |slug, changed|
        all = store.items_for(slug)
        listing = Listing.new(slug, all, store: store)
        with_ancestors(changed, all).each do |item|
          Turbo::StreamsChannel.broadcast_replace_to(
            LIST_STREAM, target: item.dom_id, partial: "work_queue/card",
            locals: { item: item, context: listing.contexts[item.key], flow: listing.flows[item.key], progress: listing.progress }
          )
          log_header(item)
        end
        project_counts(listing) if counts
      end
    end

    # The numbers in a project's title bar and the filter-chip totals it carries.
    def project_counts(listing)
      Turbo::StreamsChannel.broadcast_replace_to(
        LIST_STREAM, target: "wq_proj_cnt_#{listing.slug}", partial: "work_queue/project_counts", locals: { listing: listing }
      )
      Turbo::StreamsChannel.broadcast_replace_to(
        LIST_STREAM, target: "wq_proj_sub_#{listing.slug}", partial: "work_queue/project_sub", locals: { listing: listing }
      )
    end

    def log_header(item)
      Turbo::StreamsChannel.broadcast_replace_to(
        item_stream(item.key), target: "wq_log_header", partial: "work_queue/log_header", locals: { item: item }
      )
    end

    # The given items plus every parent above them (each once; cycle-safe).
    def with_ancestors(changed, all)
      by_n = all.index_by(&:n)
      seen = {}
      changed.each do |item|
        cur = item
        while cur && !seen.key?(cur.n)
          seen[cur.n] = cur
          cur = by_n[cur.parent]
        end
      end
      seen.values
    end

    # A CLI session's listener went online/offline: update every badge for it.
    def listener(session, listening)
      return unless session.to_s.match?(/\A[\w-]+\z/)

      item = Store::Item.new(session: session)
      Turbo::StreamsChannel.broadcast_action_to(LIST_STREAM, action: :replace, targets: ".wq-listener-#{session}",
                                                partial: "work_queue/listener", locals: { item: item, listening: listening })
      publish(type: "listener", session: session, listening: listening)
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
    def run_entries(key, entries)
      slug, n = key.split(":", 2)
      stream_entries(run_stream(key), entries, slug: slug, label: "##{n}")
    end

    # item (optional) labels each entry with its task and links #refs.
    def log_entries(agent, entries, item: nil)
      stream_entries(log_stream(agent), entries, slug: item&.slug, label: item && "##{item.n}")
    end

    def stream_entries(stream, entries, slug: nil, label: nil)
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
            partial: "work_queue/entry", locals: { entry: e, slug: slug, label: label }
          )
        end
      end
    end

    # A note (your answer, a merge result) into whichever log the item's page shows.
    def item_note(item, text)
      entry = Transcript::Entry.new(kind: "qa", body: text, at: Time.current.iso8601)
      if RunState.server_run?(item.key)
        RunState.append_stream(item.key, { "note" => text, "kind" => "qa" })
        run_entries(item.key, [entry])
      elsif (agent = Transcript.stream_id(Transcript.path_for(item)))
        log_entries(agent, [entry], item: item)
      end
    end

    def publish(payload)
      redis.publish(REDIS_CHANNEL, payload.to_json)
    rescue Redis::BaseError
      nil
    end

    def redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")

    def redis
      @redis ||= Redis.new(url: redis_url)
    end
  end
end
