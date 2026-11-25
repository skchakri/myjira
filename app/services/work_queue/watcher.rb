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

    def initialize(store: Store.new, queues: Store.dir, projects: Transcript.root, logger: Rails.logger, child_starter: ChildStarter.new, parent_closer: ParentCloser.new, worktrees: nil)
      @store = store
      @worktrees = worktrees || WorktreeQueues.new(dir: queues, logger: logger)
      @child_starter = child_starter
      @parent_closer = parent_closer
      @queues = queues.to_s
      @projects = projects.to_s
      @logger = logger
      @statuses = {}
      @prints = {}
      @shapes = {}
      @offsets = {}
      @parsers = {}
      @listening = {}
      @stalled = nil
    end

    def start
      fold_worktrees
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
      @store.projects.each do |slug, items|
        @shapes[slug] = shape(items)
        items.each do |i|
          @statuses[i.key] = i.display_status
          @prints[i.key] = fingerprint(i)
        end
      end
      @sessions = @owners = nil
      Dir.glob(File.join(@projects, "*", "*", "subagents", "agent-*.jsonl")).each { |f| @offsets[f] = File.size(f) }
      Dir.glob(File.join(@projects, "*", "*.jsonl")).each { |f| @offsets[f] = File.size(f) }
    end

    def refresh_loop
      loop do
        Rails.application.executor.wrap do
          fold_worktrees
          refresh_status
        end
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

    # Queue files named after a git worktree move into their parent repo's queue.
    def fold_worktrees
      @worktrees.call
    rescue StandardError => e
      @logger.error("[work-queue] worktree fold failed: #{e.class}: #{e.message}")
    end

    def queue_changed(paths)
      paths.uniq.each do |path|
        slug = Store.slug_for(path)
        # A worktree's queue file is never a project: fold it into its parent's
        # file (that write comes back here as the parent's change).
        next fold_worktrees if WorktreeQueues.worktree?(slug, dir: @queues)

        items = @store.items_for(slug)
        # Follow-ups start by themselves; the write re-triggers this with the cleared flag.
        next if @child_starter.call(items).any?
        # A parent with nothing of its own to merge closes once its child steps are all done.
        next if @parent_closer.call(items).any?

        @sessions = @owners = nil
        transitions = items.filter_map do |i|
          from = @statuses[i.key]
          @statuses[i.key] = i.display_status
          [i, from] if from && from != i.display_status
        end
        changed = items.reject { |i| @prints[i.key] == fingerprint(i) }
        changed.each { |i| @prints[i.key] = fingerprint(i) }
        # Redraw the whole block only when the tree itself changed: an item added,
        # removed or moved under another parent, or a finished one reopened (it may
        # not be in the page). Anything else is a card update.
        was = @shapes[slug]
        @shapes[slug] = shape(items)
        if was != @shapes[slug] || transitions.any? { |i, from| from == "done" && i.open? }
          Broadcaster.project_changed(slug, items, changed: changed, transitions: transitions)
        elsif changed.any?
          Broadcaster.items_changed(changed, transitions: transitions)
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

        Broadcaster.log_entries(id, entries, item: owners[id])
      end
    rescue StandardError => e
      @logger.error("[work-queue] log broadcast failed: #{e.class}: #{e.message}")
    end

    private

    # Sessions that own an item: only their main transcripts are streamed.
    def watched_sessions = @sessions ||= @store.all.filter_map(&:session).to_set

    # { agent id or session id => the item it works on }, rebuilt after a queue change
    # (transcripts change many times a second; the queue files do not).
    def owners
      @owners ||= @store.all.each_with_object({}) do |i, map|
        i.agent.to_s.split(/[,\s]+/).each { |a| map[a] ||= i if a.present? }
        map[i.session] ||= i if i.session.present?
      end
    end

    # What the tree looks like: who exists and who is under whom.
    def shape(items) = items.to_h { |i| [i.n, i.parent] }

    def fingerprint(item) = item.to_h.except(:updated_at).hash
  end
end
