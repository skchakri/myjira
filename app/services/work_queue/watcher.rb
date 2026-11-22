module WorkQueue
  # Long-running watcher (bin/work-queue-watch, in Procfile.dev): inotify via
  # the listen gem on the queue dir + Claude transcripts, then pushes Turbo
  # Stream broadcasts. File change → page is typically < 100 ms.
  class Watcher
    def initialize(store: Store.new, queues: Store.dir, projects: Transcript.root, logger: Rails.logger)
      @store = store
      @queues = queues.to_s
      @projects = projects.to_s
      @logger = logger
      @statuses = {}
      @offsets = {}
      @parsers = {}
    end

    def start
      prime
      listeners = [
        Listen.to(@queues, only: /\.json\z/, latency: 0.05, wait_for_delay: 0.02) { |m, a, _| queue_changed(m + a) },
        Listen.to(@projects, only: /agent-[\w-]+\.jsonl\z/, latency: 0.05, wait_for_delay: 0.02) { |m, a, _| transcripts_changed(m + a) }
      ]
      listeners.each(&:start)
      @logger.info("[work-queue] watching #{@queues} and #{@projects}")
      sleep
    end

    # Snapshot current state so the first change only emits what changed.
    def prime
      @store.all.each { |i| @statuses[i.key] = i.display_status }
      Dir.glob(File.join(@projects, "*", "*", "subagents", "agent-*.jsonl")).each { |f| @offsets[f] = File.size(f) }
    end

    def queue_changed(paths)
      paths.uniq.each do |path|
        slug = Store.slug_for(path)
        items = @store.items_for(slug)
        transitions = items.filter_map do |i|
          from = @statuses[i.key]
          @statuses[i.key] = i.display_status
          [i, from] if from && from != i.display_status
        end
        Broadcaster.project_changed(slug, items, transitions: transitions)
      end
    rescue StandardError => e
      @logger.error("[work-queue] queue broadcast failed: #{e.class}: #{e.message}")
    end

    def transcripts_changed(paths)
      paths.uniq.each do |path|
        agent = Transcript.agent_id(path)
        next unless agent

        parser = (@parsers[path] ||= Transcript.new)
        entries, @offsets[path] = parser.parse_file(path, from: @offsets.fetch(path, 0))
        Broadcaster.log_entries(agent, entries)
      end
    rescue StandardError => e
      @logger.error("[work-queue] log broadcast failed: #{e.class}: #{e.message}")
    end
  end
end
