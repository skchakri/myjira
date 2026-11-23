module WorkQueue
  # Follow-ups (items with a parent) never wait for the person's approval. The
  # CLI work-queue mod files them "awaiting approval"; the watcher hands every
  # queue change to this class, which clears the flag and starts them: through
  # the owning CLI session when it is listening, else on the server runner.
  # They run in parallel with their parent (within the runner's slot cap) and
  # ship in the parent's bundle PR (see Bundler).
  class ChildStarter
    def initialize(writer: QueueWriter.new, dispatcher: Dispatcher, enqueue: RunState.method(:enqueue))
      @writer = writer
      @dispatcher = dispatcher
      @enqueue = enqueue
    end

    # Returns the items it started.
    def call(items)
      by_n = items.index_by(&:n)
      items.select { |i| startable?(i, by_n) }.each { |i| start(i) }
    end

    private

    def startable?(item, by_n)
      item.parent.present? && by_n.key?(item.parent) && item.awaiting_approval && %w[triage queued].include?(item.status)
    end

    def start(item)
      @writer.update(item.slug, item.n, log: "Follow-up of ##{item.parent}: started without approval (ships in its parent's PR)") do |i|
        i.delete("awaitingApproval")
        i["status"] = "queued"
      end
      item.awaiting_approval = false
      dispatch = @dispatcher.new(item)
      if dispatch.listening?
        dispatch.run_now
      else
        RunState.set(item.key, { "repo" => Workspace.repo_for(item.slug) }.compact)
        @enqueue.call("start", item.key)
      end
    end
  end
end
