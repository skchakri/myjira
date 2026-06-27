# The project board: a per-folder priority queue of typed work items (task /
# feature / issue / ask) moving through the 8-state board workflow, plus the
# autopilot controls. Live updates ride on Turbo refresh broadcasts to
# [project, :board]; drag-to-reorder and inline edits persist via the actions here.
class BoardsController < ApplicationController
  before_action :set_project, except: [:stop_all, :resume_all]
  before_action :set_task, only: [:update_item, :pick_up, :run_tests, :request_merge, :reject_pr, :add_comment, :plan, :pr]

  def show
    @active_label = params[:label].to_s.strip.downcase.presence
    @all_labels = @project.board_labels
    @groups = @project.board_groups(label: @active_label)
    @done_count = @project.tasks.where(board_state: "done").count
    @inflight_launch = @project.current_board_launch
  end

  # Persist a drag: `order` is every visible item id top-to-bottom (new priority);
  # an item dragged into a different status group also carries moved_id/moved_state.
  def reorder
    ids = Array(params[:order]).map(&:to_s)
    Task.transaction do
      if params[:moved_id].present? && Task::BOARD_STATES.include?(params[:moved_state].to_s)
        item = @project.tasks.find(params[:moved_id])
        item.update!(board_state: params[:moved_state])
      end
      ids.each_with_index do |id, i|
        @project.tasks.where(id: id).update_all(position: i + 1, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      end
    end
    refresh_board!
    head :ok
  end

  def create_item
    attrs = create_params
    # The "just dump context" path: title left blank → derive a placeholder now so
    # the board shows something sensible immediately, and let a triage agent assign
    # the real title/type/priority from the description + images.
    delegate = attrs[:title].blank?
    attrs[:title] = derive_title(attrs[:description]) if delegate

    item = @project.tasks.new(attrs)
    item.board_state = "pending"
    item.source = "web"
    if item.save
      launch = (Board::Pipeline.launch_triage!(item, initiated_by: "web") if delegate && item.has_context?)
      notice = if launch
        "Item added — assigning a title, type & priority from your context. You can edit them anytime."
      else
        "Item added."
      end
      redirect_to board_path(@project), notice: notice
    else
      redirect_to board_path(@project), alert: item.errors.full_messages.to_sentence
    end
  end

  # Inline edits from the board (status dropdown, type, priority, title, plan).
  def update_item
    @task.assign_attributes(update_params)
    @task.plan_updated_at = Time.current if @task.plan_changed?
    @task.save!
    refresh_board! unless @task.saved_change_to_board_state? # model already broadcast that
    if params[:return_to] == "task"
      redirect_to [@project, @task], notice: "Status updated."
    else
      head :no_content
    end
  end

  # Manually hand the item to the next pipeline agent (the same step autopilot
  # would run next), regardless of whether autopilot is enabled.
  def pick_up
    launch = Board::Pipeline.pick_up!(@task, initiated_by: "web")
    if launch
      open_session_in_browser(launch)
      redirect_to board_path(@project), notice: "Queued #{launch.pipeline_step} agent for “#{@task.title}”."
    else
      redirect_to board_path(@project), alert: "Nothing to do for this item (state: #{@task.board_state})."
    end
  end

  # Manually trigger the test leg for a finished item (the Run-tests button).
  def run_tests
    run = Board::TestLeg.run!(@task, initiated_by: "web")
    if run
      redirect_to test_run_path(run), notice: "Test run started."
    else
      redirect_to board_path(@project), alert: "No test plan yet for this item — an agent generates one when it finishes."
    end
  end

  # "Approve & merge" on an in_review item: flag it so the host daemon runs
  # `gh pr merge` (the container has no GitHub access) and flips it to done.
  def request_merge
    if @task.request_merge!
      refresh_board!
      redirect_back fallback_location: board_path(@project),
                    notice: "Approved — merging the PR. It moves to Done once GitHub confirms the merge."
    else
      redirect_back fallback_location: board_path(@project),
                    alert: "Can't merge: the item must be in review with an open PR."
    end
  end

  # "Reject" on an in_review item / PR modal: decline the changes. Moves to failed
  # and leaves the PR open on GitHub; an optional reason is logged as a comment.
  def reject_pr
    if @task.reject_pr!(note: params[:reason])
      refresh_board!
      redirect_back fallback_location: board_path(@project), notice: "Rejected — moved to Failed. The PR is left open on GitHub."
    else
      redirect_back fallback_location: board_path(@project), alert: "Can't reject: the item must be in review with an open PR."
    end
  end

  # Add an append-only note to an item (from the board or task page). Blank bodies
  # are rejected with a flash. Always returns to the task page where the log lives.
  def add_comment
    body = params.dig(:comment, :body).to_s.strip
    if body.present?
      @task.comments.create!(author: "you", body: body)
      redirect_to [@project, @task], notice: "Comment added."
    else
      redirect_to [@project, @task], alert: "Comment can't be blank."
    end
  end

  # Plan + PR modals rendered into the #board_modal turbo-frame.
  def plan
    render partial: "boards/plan_modal", locals: { project: @project, task: @task }
  end

  def pr
    render partial: "boards/pr_modal", locals: { project: @project, task: @task }
  end

  # Manually advance this project's pipeline by one step now (without waiting for
  # the daemon heartbeat). Ignores the enabled flag/cap but stays one-at-a-time.
  def tick_now
    result = Autopilot::Orchestrator.run_once(@project)
    if result
      redirect_to board_path(@project), notice: "Launched #{result[:action]} agent."
    else
      redirect_to board_path(@project), alert: "Nothing to launch (already working, or no actionable item)."
    end
  end

  # Per-project autopilot controls (enable, pause, daily cap). Auto-submitted
  # inline; the board morphs from the refresh broadcast, so no redirect.
  def autopilot
    @project.update!(autopilot_params)
    refresh_board!
    head :no_content
  end

  # Global kill switch.
  def stop_all
    Setting.autopilot_stopped = true
    redirect_back fallback_location: clients_path, notice: "Autopilot stopped across all projects."
  end

  def resume_all
    Setting.autopilot_stopped = false
    redirect_back fallback_location: clients_path, notice: "Autopilot resumed."
  end

  private

  def set_project
    @project = Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
  end

  def set_task
    @task = @project.tasks.find(params[:id])
  end

  def create_params
    params.require(:task).permit(:title, :item_type, :description, :priority, :labels_text, attachments: [], labels: [])
  end

  # A stand-in title from the dump's first meaningful line, shown until the triage
  # agent replaces it. Strips common email/quote noise so it reads cleanly.
  def derive_title(description)
    line = description.to_s.each_line.map(&:strip).find do |l|
      l.present? && !l.start_with?(">", "On ", "From:", "To:", "Subject:", "Sent:", "Date:")
    end
    line = line.to_s.sub(/\ASubject:\s*/i, "")
    line.present? ? line.truncate(80) : "Untitled item"
  end

  def update_params
    params.require(:task).permit(:title, :item_type, :board_state, :agent_role, :priority, :plan, :description, :changelog_summary, :labels_text, labels: [])
  end

  def autopilot_params
    params.require(:project).permit(:autopilot_enabled, :autopilot_paused, :autopilot_daily_cap,
                                    :autopilot_review_enabled, :base_branch)
  end

  def refresh_board!
    Turbo::StreamsChannel.broadcast_refresh_to([@project, :board])
  end

  # Open the freshly-queued session's transcript so the user can watch it run —
  # mirrors the global "open the relay ticket" convenience.
  def open_session_in_browser(launch)
    # No-op server-side; the redirect notice links the session. Kept as a seam.
    launch
  end
end
