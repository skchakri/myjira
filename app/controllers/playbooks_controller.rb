# Web CRUD for Playbooks — saved, reusable run recipes scoped to a project. A
# playbook can be triggered (queues a SessionLaunch + records a pending
# PlaybookRun) or scheduled (creates an AgentSchedule carrying playbook_id so the
# daemon's tick fires it on a cron). Mirrors TestPlansController's shape and
# AgentBuildsController's missing-repo guard.
class PlaybooksController < ApplicationController
  before_action :set_project
  before_action :set_playbook, only: [:show, :edit, :update, :destroy, :trigger, :schedule]

  def index
    @playbooks = @project.playbooks.recent.includes(:agent).to_a
    @metrics = Playbook.metrics_for(@playbooks)
  end

  def show
    @runs = @playbook.playbook_runs.recent.includes(:session_launch).limit(50)
    @metrics = @playbook.metrics
  end

  def new
    @playbook = @project.playbooks.new
  end

  def create
    @playbook = @project.playbooks.new(playbook_params)
    if @playbook.save
      redirect_to [@project, @playbook], notice: "Playbook created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @playbook.update(playbook_params)
      redirect_to [@project, @playbook], notice: "Playbook updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @playbook.destroy
    redirect_to project_playbooks_path(@project), notice: "Playbook deleted."
  end

  # Run it once now — queues a SessionLaunch and records a pending PlaybookRun.
  def trigger
    return missing_repo if @project.repo_path.blank?

    run = @playbook.trigger!(for_project: @project)
    if run
      redirect_to [@project, @playbook], notice: "Triggered “#{@playbook.name}” — the session appears in #{@project.name}'s conversations."
    else
      missing_repo
    end
  end

  # Put it on a cron — creates an AgentSchedule carrying this playbook's id, so
  # the host daemon's tick fires it and records a PlaybookRun each time.
  def schedule
    schedule = @project.agent_schedules.new(
      playbook: @playbook,
      agent: @playbook.agent,
      prompt: @playbook.run_prompt,
      model: @playbook.model.presence || "default",
      permission_mode: @playbook.permission_mode.presence || "default",
      cron: params[:cron].to_s.strip
    )

    if schedule.save
      redirect_to [@project, @playbook],
        notice: "Scheduled “#{@playbook.name}” · #{schedule.cron} — next run #{helpers.format_time(schedule.next_run_at)}."
    else
      redirect_to [@project, @playbook],
        alert: "Couldn't schedule: #{schedule.errors.full_messages.to_sentence}"
    end
  end

  private

  def set_project
    @project = Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
  end

  def set_playbook
    @playbook = @project.playbooks.find(params[:id])
  end

  def playbook_params
    params.require(:playbook).permit(:name, :body, :success_criteria, :guardrails,
                                     :agent_id, :model, :permission_mode, :enabled)
  end

  def missing_repo
    redirect_to [@project, @playbook],
      alert: "No repo path known for #{@project.name} yet — run Claude in that folder once so myjira learns where it is."
  end
end
