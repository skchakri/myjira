# Decides and launches the next board pipeline step for an item, and is the single
# place the manual "Pick up" button and the autopilot orchestrator both go through.
# Each step is a Claude CLI session spawned by the host daemon (via SessionLaunch),
# running a global slash command that fetches the item from the myjira API and
# works it end-to-end, reporting status back through the same API.
module Board
  module Pipeline
    module_function

    # board_state / agent_role  →  pipeline step  →  global slash command.
    COMMANDS = {
      "triage"      => "board-triage",
      "review"      => "board-review",
      "planning"    => "board-plan",
      "engineering" => "board-engineer",
      "debugger"    => "board-debug",
      "answer"      => "board-answer",
      "resolve_conflicts" => "board-resolve-conflicts"
    }.freeze

    def base_url
      ENV.fetch("MYJIRA_BASE_URL", "http://localhost:1200")
    end

    # The next step an actionable item needs, or nil if it is not the pipeline's
    # turn (in_progress/waiting/hold/in_review/done, or a failed item out of tries).
    def next_step_for(task)
      case task.board_state
      when "pending"
        "planning"
      when "failed"
        task.autopilot_exhausted? ? nil : "planning"
      when "planned"
        case task.agent_role
        when "engineering" then "engineering"
        when "debugger"    then "debugger"
        when "answer_only" then "answer"
        else "planning" # not yet routed → re-plan to assign a role
        end
      end
    end

    # Queue whatever step this item needs next. Returns the SessionLaunch, or nil
    # if there is nothing to do or the project has no repo to run in.
    def pick_up!(task, initiated_by: "web")
      step = next_step_for(task)
      return nil unless step
      launch_step!(task, step: step, initiated_by: initiated_by)
    end

    def launch_step!(task, step:, initiated_by: "system")
      project = task.project
      return nil if project.repo_path.blank?
      command = COMMANDS.fetch(step)
      # Cost-aware auto-routing: replace the static "default" slot with a concrete
      # tier scored from the item's existing fields. Defensive fallback to "default"
      # so a blank pick can never break a launch.
      model = Board::ModelRouter.pick(task: task, step: step).presence || "default"
      launch = SessionLaunch.queue!(
        project: project,
        prompt: "/#{command} #{task.id} #{project.slug} #{base_url} #{project.base_branch_or_default}",
        model: model,
        permission_mode: "bypassPermissions",
        title: "#{step}: #{task.title}".truncate(80),
        source: "board",
        task: task,
        pipeline_step: step
      )
      launch.emit_worklog("model.routed", status: "info",
        label: "Auto-routed model → #{model}", payload: { step: step, model: model })
      # Flip to in_progress the instant the session is queued. This closes the gap
      # where a launched-but-not-yet-started item (the agent hasn't PATCHed back
      # yet) looked idle and let the next orchestrator tick double-launch the same
      # project. in_progress is now the single source of truth for both
      # Project#board_busy? and the daemon session reaper.
      task.update!(board_state: "in_progress", picked_up_at: Time.current)
      Rails.logger.info("[board] launched #{step} for task #{task.id} (#{project.slug})")
      # The in_progress flip already morphs the board via Task#broadcast_board, but
      # broadcast explicitly too so the live "processing now" indicator never depends
      # on that side effect (and stays correct if the flip is ever moved/removed).
      broadcast_board(project)
      launch
    end

    # Queue a resolve-conflicts agent session for an in_review item whose PR has
    # diverged from main. UI/manual-triggered only (never from next_step_for, so
    # autopilot can't auto-resolve conflicts unattended). The spawned session merges
    # origin/main, resolves hunks, lint+tests, pushes, squash-merges, and closes the
    # item. Returns the SessionLaunch, or nil if the project has no repo to run in.
    def launch_resolve_conflicts!(task, initiated_by: "web")
      project = task.project
      return nil if project.repo_path.blank?
      launch = SessionLaunch.queue!(
        project: project,
        prompt: "/board-resolve-conflicts #{task.id} #{project.slug} #{base_url} #{project.base_branch_or_default}",
        model: "default",
        permission_mode: "bypassPermissions",
        title: "resolve conflicts: #{task.title}".truncate(80),
        source: "board",
        task: task,
        pipeline_step: "resolve_conflicts"
      )
      Rails.logger.info("[board] launched resolve_conflicts for task #{task.id} (#{project.slug}) by #{initiated_by}")
      broadcast_board(project)
      launch
    end

    # Queue a triage pass for a freshly-dumped item: a Claude session reads the
    # description + any attached images and assigns a proper title, type, and
    # priority via the API. Returns the launch, or nil if the project has no repo
    # (nothing to spawn `claude` in — the item keeps its derived placeholder title).
    def launch_triage!(task, initiated_by: "web")
      project = task.project
      return nil if project.repo_path.blank?
      launch = SessionLaunch.queue!(
        project: project,
        prompt: "/board-triage #{task.id} #{project.slug} #{base_url}",
        model: "default",
        permission_mode: "bypassPermissions",
        title: "triage: #{task.title}".truncate(80),
        source: "board",
        task: task,
        pipeline_step: "triage"
      )
      Rails.logger.info("[board] launched triage for task #{task.id} (#{project.slug}) by #{initiated_by}")
      broadcast_board(project)
      launch
    end

    # Queue the morning review for a project (used by pick-up-all / schedules).
    def launch_review!(project, initiated_by: "system")
      return nil if project.repo_path.blank?
      launch = SessionLaunch.queue!(
        project: project,
        prompt: "/board-review #{project.slug} #{base_url}",
        model: "default",
        permission_mode: "bypassPermissions",
        title: "review: #{project.name}".truncate(80),
        source: "board",
        pipeline_step: "review"
      )
      broadcast_board(project)
      launch
    end

    # Morph an already-open board the instant a launch is queued, so the per-item
    # "processing now" indicator (boards/_item, _kanban_card) and the header pill
    # appear live regardless of who queued the step. Autopilot's daemon path and the
    # triage/resolve/review paths otherwise queue launches without any board_state
    # change, so nothing would broadcast. Mirrors Task#broadcast_board's stream.
    def broadcast_board(project)
      Turbo::StreamsChannel.broadcast_refresh_to([project, :board])
    end
  end
end
