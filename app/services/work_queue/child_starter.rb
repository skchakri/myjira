module WorkQueue
  # Decides what happens to follow-ups (items with a parent) that agents file.
  # The watcher hands every queue change of a project to #call.
  #
  #   must-do (the default)  starts by itself, as before, unless the project already has
  #                          too much waiting on the person: then it is held ("followUp.held")
  #                          and released oldest first once the person has caught up.
  #   nice-to-have           never starts by itself; it waits as a batch on its parent
  #                          (Start / Drop in the detail pane and the inbox).
  #   typed by the person    ("＋ Add child item") and Run now always start.
  #
  # Starting goes through the owning CLI session when it is listening, else the
  # server runner. Follow-ups run in parallel with their parent (within the runner's
  # slot cap) and ship in the parent's bundle PR (see Bundler).
  class ChildStarter
    def initialize(writer: QueueWriter.new, dispatcher: Dispatcher, enqueue: RunState.method(:enqueue),
                   limit: RunState.method(:review_limit), waiting: nil, since: nil)
      @writer = writer
      @dispatcher = dispatcher
      @enqueue = enqueue
      @limit = limit
      @waiting = waiting || ->(items) { Inbox.waiting_count(items) }
      @since = since
    end

    # Returns the items it changed (started, held or released).
    def call(items)
      by_n = items.index_by(&:n)
      follow_ups = items.select { |i| i.parent.present? && by_n.key?(i.parent) && i.unstarted? && !i.to_decide? }
      fresh = follow_ups.select { |i| candidate?(i) }
      held = follow_ups.select(&:held?)
      legacy = follow_ups.select { |i| i.awaiting_approval && !i.held? }
      return [] if fresh.empty? && held.empty? && legacy.empty?

      limit = @limit.call(items.first.slug)
      waiting = limit ? @waiting.call(items) : 0
      if limit && waiting >= limit
        (fresh + legacy).uniq(&:key).map { |i| hold(i, waiting, limit) }
      else
        held.sort_by(&:n).map { |i| release(i) } +
          legacy.map { |i| start(i, "Follow-up of ##{i.parent}: started without approval (ships in its parent's PR)") }
      end
    end

    # "Start anyway" / Start selected: the person's own choice, never limited.
    def start_now(item, note: "Started by you from myjira")
      start(item, note)
    end

    def drop(item)
      @writer.follow_up(item.slug, item.n, { held: nil }, log: "Dropped by you from myjira") { |i| i["status"] = "dropped" }
      item
    end

    private

    # An agent-filed must-do follow-up nobody has started, held or admitted yet.
    def candidate?(item)
      info = item.follow_up_info
      return false if info["held"] || info["admitted"] || info["by"] == "person" || item.awaiting_approval

      item.created_at.present? && item.created_at >= since
    end

    def since = @since ||= RunState.followup_limits_since

    def hold(item, waiting, limit)
      @writer.follow_up(item.slug, item.n, { held: true },
                        log: "Held: #{waiting} #{'task'.pluralize(waiting)} #{waiting == 1 ? 'is' : 'are'} waiting on you in this project (limit #{limit})") do |i|
        i.delete("awaitingApproval")
        i["status"] = "queued"
      end
      item.awaiting_approval = false
      item.status = "queued"
      item.follow_up = item.follow_up_info.merge("held" => true)
      item
    end

    def release(item)
      start(item, "Released: you caught up, so this follow-up of ##{item.parent} starts now")
    end

    def start(item, note)
      @writer.follow_up(item.slug, item.n, { held: nil, admitted: true }, log: note) do |i|
        i.delete("awaitingApproval")
        i["status"] = "queued"
      end
      item.awaiting_approval = false
      item.follow_up = item.follow_up_info.except("held").merge("admitted" => true)
      dispatch = @dispatcher.new(item)
      if dispatch.listening?
        dispatch.run_now
      else
        RunState.set(item.key, { "repo" => Workspace.repo_for(item.slug) }.compact)
        @enqueue.call("start", item.key)
      end
      item
    end
  end
end
