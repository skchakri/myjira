module WorkQueue
  # Long-running watcher (bin/work-queue-watch, in Procfile.dev): inotify via
  # the listen gem on the queue dir + Claude transcripts, then pushes Turbo
  # Stream broadcasts. File change → page is typically < 100 ms.
  #
  # A background loop also refreshes git/PR status into StatusCache (so pages
  # never run git/gh) and CLI listener online/offline, pushing only the cards
  # that changed.
  class Watcher
    REFRESH_EVERY = ENV.fetch("WORK_QUEUE_REFRESH_SECONDS", 20).to_i
    TRANSCRIPT = /(?:agent-[\w-]+|\A[0-9a-f-]{36})\.jsonl\z/

    def initialize(store: Store.new, queues: Store.dir, projects: Transcript.root, logger: Rails.logger, child_starter: ChildStarter.new)
      @store = store
      @child_starter = child_starter
      @queues = queues.to_s
      @projects = projects.to_s
      @logger = logger
      @statuses = {}
      @prints = {}
      @offsets = {}
      @parsers = {}
      @listening = {}
      @stalled = nil
    end

    def start
      prime
      listeners = [
        Listen.to(@queues, only: /\.json\z/, latency: 0.05, wait_for_delay: 0.02) { |m, a, _| queue_changed(m + a) },
        Listen.to(@projects, only: /\.jsonl\z/, latency: 0.05, wait_for_delay: 0.02) { |m, a, _| transcripts_changed(m + a) }
      ]
      listeners.each(&:start)
      @logger.info("[work-queue] watching #{@queues} and #{@projects}")
      refresh_loop
    end

    # Snapshot current state so the first change only emits what changed.
    def prime
      @store.all.each do |i|
        @statuses[i.key] = i.display_status
        @prints[i.key] = fingerprint(i)
      end
      @sessions = nil
      Dir.glob(File.join(@projects, "*", "*", "subagents", "agent-*.jsonl")).each { |f| @offsets[f] = File.size(f) }
      Dir.glob(File.join(@projects, "*", "*.jsonl")).each { |f| @offsets[f] = File.size(f) }
    end

    def refresh_loop
      loop do
        Rails.application.executor.wrap { refresh_status }
        sleep REFRESH_EVERY
      end
    end

    # Git/PR status for open items, plus deploy status for recently done items
    # that aren't live yet (PRs in parallel; gh is ~0.5-1 s per call).
    def refresh_status
      all = @store.all
      items = all.select(&:open?)
      items += all.select { |i| StatusCache.delivering?(i) }
      changed = Queue.new
      items.each_slice(8) do |batch|
        batch.map do |item|
          Thread.new do
            Rails.application.executor.wrap { changed << item if StatusCache.refresh(item, store: @store) }
          end
        end.each(&:join)
      end
      list = Array.new(changed.size) { changed.pop }
      list |= stall_changes(items)
      Broadcaster.cards_changed(list) if list.any?
      refresh_listeners(items.select(&:open?))
    rescue StandardError => e
      @logger.error("[work-queue] status refresh failed: #{e.class}: #{e.message}")
    end

    # Running items that crossed the stall threshold (or came back to life) since the
    # last sweep. Their queue file did not change, so nothing else would redraw them.
    def stall_changes(items)
      running = items.select { |i| i.status == "running" }
      now = running.select { |i| ItemContext.new(i, store: @store).flow.stalled? }.to_set(&:key)
      was = @stalled
      @stalled = now
      return [] if was.nil?

      running.select { |i| was.include?(i.key) != now.include?(i.key) }
    end

    def refresh_listeners(items)
      sessions = items.filter_map(&:session).uniq
      Conversation.where(session_id: sessions).find_each do |c|
        now = c.listening?
        Broadcaster.listener(c.session_id, now) if @listening.key?(c.session_id) && @listening[c.session_id] != now
        @listening[c.session_id] = now
      end
    end

    def queue_changed(paths)
      paths.uniq.each do |path|
        slug = Store.slug_for(path)
        items = @store.items_for(slug)
        # Follow-ups start by themselves; the write re-triggers this with the cleared flag.
        next if @child_starter.call(items).any?

        @sessions = nil
        transitions = items.filter_map do |i|
          from = @statuses[i.key]
          @statuses[i.key] = i.display_status
          [i, from] if from && from != i.display_status
        end
        changed = items.reject { |i| @prints[i.key] == fingerprint(i) }
        structural = transitions.any? || changed.any? { |i| !@prints.key?(i.key) }
        changed.each { |i| @prints[i.key] = fingerprint(i) }
        if structural
          Broadcaster.project_changed(slug, items, transitions: transitions)
        else
          Broadcaster.cards_changed(changed)
        end
      end
    rescue StandardError => e
      @logger.error("[work-queue] queue broadcast failed: #{e.class}: #{e.message}")
    end

    def transcripts_changed(paths)
      paths.uniq.each do |path|
        id = Transcript.stream_id(path)
        next unless id
        next unless Transcript.agent_id(path) || watched_sessions.include?(id)

        parser = (@parsers[path] ||= Transcript.new)
        entries, @offsets[path] = parser.parse_file(path, from: @offsets.fetch(path) { [File.size(path) - 200_000, 0].max })
        next if entries.empty?

        item = @store.all.find { |i| i.agent.to_s.split(/[,\s]+/).include?(id) || i.session == id }
        Broadcaster.log_entries(id, entries, item: item)
      end
    rescue StandardError => e
      @logger.error("[work-queue] log broadcast failed: #{e.class}: #{e.message}")
    end

    private

    # Sessions that own an item: only their main transcripts are streamed.
    def watched_sessions = @sessions ||= @store.all.filter_map(&:session).to_set

    def fingerprint(item) = item.to_h.except(:updated_at).hash
  end
end
