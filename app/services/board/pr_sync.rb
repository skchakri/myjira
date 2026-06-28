# Reconciles in_review board items with their GitHub PR. The Rails container has
# no GitHub access, so the host daemon does the `gh` calls: it GETs #work, runs
# gh per item, and POSTs the outcomes back, which #apply! turns into board moves.
#
#   • "Approve & merge" (human)  → daemon `gh pr merge` → ok → done+merged
#   • PR merged directly on GitHub → daemon poll sees "merged" → done+merged
#   • PR closed without merging     → daemon poll sees "closed" → failed
module Board
  module PrSync
    module_function

    # How stale an in_review PR's last poll must be before we re-check it, so a
    # ~60s daemon heartbeat doesn't hit GitHub for every PR every loop.
    POLL_INTERVAL = 5.minutes

    # The daemon's to-do list for this tick.
    def work
      {
        to_merge: Task.awaiting_merge.includes(:project).map { |t| descriptor(t) },
        to_poll:  Task.pr_pollable(POLL_INTERVAL.ago).includes(:project).map { |t| descriptor(t) }
      }
    end

    def descriptor(task)
      { task_id: task.id, slug: task.project.slug, pr_url: task.pr_url, pr_number: task.pr_number }
    end

    # Apply one daemon-reported outcome; returns a short result tag for the log.
    #   action "merge": ok → done+merged; else stay in_review with the error note.
    #   action "poll" : state merged → done+merged; closed → failed; else throttle.
    def apply!(task, action:, ok: nil, state: nil, mergeable: nil, error: nil)
      case action.to_s
      when "merge"
        return "merge_failed".tap { task.fail_merge!(error.to_s.presence || "unknown error") } unless ok

        task.complete_merge!
        "merged"
      when "poll"
        case state.to_s
        when "merged"
          task.complete_merge!
          "merged"
        when "closed"
          task.update!(board_state: "failed", pr_state: "closed",
                       agent_notes: "PR #{task.pr_number} was closed on GitHub without merging.")
          "closed"
        else
          # Still open — stamp the poll time so it isn't re-checked next loop, and
          # persist gh's mergeable verdict so the board can surface conflicts. Don't
          # clobber an in-flight resolution's stamp (conflict_resolution_at is the
          # button guard; pr_mergeable is just the displayed state).
          task.update_columns(pr_mergeable: mergeable.to_s.presence, # rubocop:disable Rails/SkipsModelValidations
                              pr_synced_at: Time.current, updated_at: Time.current)
          "open"
        end
      else
        "ignored"
      end
    end
  end
end
