# The autopilot orchestrator: each tick it advances every active project's board
# by exactly ONE pipeline step (the one-item-at-a-time guardrail), respecting the
# global kill switch, per-project pause, and the daily run cap. It does not run
# agents itself — it queues the next SessionLaunch (planning/engineering/debugger/
# answer/review); the host daemon spawns them and the agents report back via the API.
#
# Driven every ~60s from the daemon's existing schedule tick (Api::V1::
# AgentSchedulesController#tick) and from the dedicated /api/v1/autopilot/tick.
# Per-project work happens inside `with_lock` so overlapping ticks can't
# double-launch.
module Autopilot
  module Orchestrator
    module_function

    # UTC hour at/after which the daily review may run (≈ the user's morning).
    REVIEW_HOUR = ENV.fetch("MYJIRA_REVIEW_HOUR", "13").to_i
    # Fleet-wide ceiling: at most this many board agent sessions run across ALL
    # projects at once. Keeps "autopilot on every project" from spawning a session
    # per project simultaneously. Per-project one-at-a-time still applies on top.
    GLOBAL_MAX_CONCURRENT = ENV.fetch("MYJIRA_AUTOPILOT_MAX_CONCURRENT", "3").to_i

    # Advance eligible projects by one step each, up to the free global slots.
    def tick!
      return { ok: true, stopped: true, launched: [] } if Setting.autopilot_stopped?
      slots = GLOBAL_MAX_CONCURRENT - global_inflight_count
      launched = []
      if slots.positive?
        Project.where(autopilot_enabled: true, autopilot_paused: false).find_each do |project|
          break if launched.size >= slots
          result = tick_project(project)
          launched << result if result
        rescue StandardError => e
          Rails.logger.error("[autopilot] #{project.slug} tick failed: #{e.class} #{e.message}")
        end
      end
      { ok: true, launched: launched, global_inflight: global_inflight_count, free_slots: slots }
    end

    # Board agent sessions currently running across the whole fleet (queued/
    # launching, or launched and still active by conversation recency).
    def global_inflight_count
      board = SessionLaunch.where.not(pipeline_step: nil)
      board.where(status: %w[pending launching]).count +
        board.where(status: "launched").joins(:conversation)
             .where("COALESCE(conversations.last_message_at, session_launches.launched_at) >= ?",
                    Project::BOARD_LAUNCH_BUSY_WINDOW.ago).count
    end

    # One automatic step for a project, fully gated (enabled/paused/stopped/cap)
    # and serialized by a row lock. Returns the launch summary or nil.
    def tick_project(project)
      launched = nil
      project.with_lock do
        next unless project.autopilot_active?
        next if project.inflight_board_launch?
        launch = should_review?(project) ? Board::Pipeline.launch_review!(project) : advance_project(project)
        if launch
          project.bump_autopilot_runs!
          launched = summary(project, launch)
        end
      end
      launched
    end

    # Manual "Run pipeline now" from the board — advance the top item once,
    # ignoring the enabled flag and the daily cap (but still one-at-a-time).
    def run_once(project)
      launched = nil
      project.with_lock do
        next if Setting.autopilot_stopped?
        next if project.inflight_board_launch?
        launch = advance_project(project)
        launched = summary(project, launch) if launch
      end
      launched
    end

    # Launch the next step for the first actionable item that has one. Items that
    # have exhausted their autopilot attempts are parked to `waiting` for a human
    # and skipped, so one broken item can't consume the queue.
    def advance_project(project)
      project.tasks.actionable.board_ordered.each do |item|
        step = Board::Pipeline.next_step_for(item)
        return Board::Pipeline.launch_step!(item, step: step) if step

        if item.board_state == "failed" && item.autopilot_exhausted?
          item.update!(board_state: "waiting",
                       agent_notes: [item.agent_notes, "Parked for review after #{item.autopilot_attempts} failed autopilot attempts."].compact.join(" ").strip)
        end
      end
      nil
    end

    # Once-per-day, at/after the review hour, if no review has run today — and only
    # when the project opted into the review agent (clients turn it off and add
    # items by hand, while the build pipeline still runs autonomously).
    def should_review?(project)
      return false unless project.autopilot_review_enabled?
      return false if Time.current.utc.hour < REVIEW_HOUR
      project.session_launches.where(pipeline_step: "review")
             .where(created_at: Time.current.beginning_of_day..).none?
    end

    # Read-only snapshot for the board header / the /autopilot/status endpoint.
    def status
      {
        stopped: Setting.autopilot_stopped?,
        review_hour_utc: REVIEW_HOUR,
        global_inflight: global_inflight_count,
        max_concurrent: GLOBAL_MAX_CONCURRENT,
        projects: Project.where(autopilot_enabled: true).map do |p|
          {
            slug: p.slug, active: p.autopilot_active?, paused: p.autopilot_paused?,
            in_flight: p.inflight_board_launch?,
            runs_today: p.autopilot_runs_today, daily_cap: p.autopilot_daily_cap,
            next_item: p.next_board_item&.title
          }
        end
      }
    end

    def summary(project, launch)
      { project: project.slug, action: (launch.pipeline_step || "review"),
        task: launch.task_id, launch: launch.id }
    end
  end
end
