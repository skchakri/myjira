# Reconciles in_progress board items with their Claude CLI tmux session. The Rails
# container can't see host tmux, so the host daemon does the check: it GETs #work,
# runs `tmux has-session` / `list-windows` per item, and POSTs which windows are
# still alive. #apply! returns a dead session's item to the queue so the autopilot
# (Project#board_busy?) can pick the next one — the self-healing half of the
# strict-serial guard. Mirrors Board::PrSync.
module Board
  module SessionSync
    module_function

    # Don't reap a launch whose tmux window may still be mid-spawn.
    SPAWN_GRACE = 90.seconds

    # The daemon's check-list: in_progress items whose latest board launch is
    # "launched" with a tmux target, past the spawn grace.
    def work
      Task.in_progress.includes(:project).filter_map do |task|
        launch = task.session_launches.where.not(pipeline_step: nil)
                     .where(status: "launched").where.not(tmux_target: [nil, ""])
                     .order(launched_at: :desc).first
        next unless launch
        next if launch.launched_at && launch.launched_at > SPAWN_GRACE.ago
        { task_id: task.id, launch_id: launch.id, slug: task.project.slug,
          tmux_target: launch.tmux_target }
      end
    end

    # Apply one daemon-reported liveness outcome.
    #   alive:true  → still running, leave it.
    #   alive:false → window gone; if the agent never moved it out of in_progress,
    #                 return it to the queue (bump attempts, note).
    def apply!(task, alive:)
      return "alive" if alive
      return "not_in_progress" unless task.board_state == "in_progress"

      requeue!(task, "Session ended without reporting a result; re-queued.")
    end

    # In-Rails self-heal for launches that never spawned. A launch that FAILS
    # (e.g. a tmux "index 0 in use" collision) sets tmux_target=nil, so #work
    # can't see it and the item would wedge in_progress forever — blocking the
    # project's strict-serial guard. A failed launch created no host window, so
    # there's nothing for the daemon to check; requeue it directly. Runs each
    # autopilot tick. Returns the ids it requeued.
    def reap_failed!
      Task.in_progress.includes(:session_launches).filter_map do |task|
        next unless task.board_state == "in_progress"

        launch = task.session_launches.select { |l| l.pipeline_step.present? }
                     .max_by(&:created_at)
        next unless launch&.status == "failed"
        next if launch.created_at > SPAWN_GRACE.ago

        requeue!(task, "Launch failed to spawn (#{launch.error}); re-queued.")
        task.id
      end
    end

    def requeue!(task, note)
      task.update!(board_state: "pending",
                   autopilot_attempts: task.autopilot_attempts + 1,
                   agent_notes: note)
      "requeued"
    end
  end
end
