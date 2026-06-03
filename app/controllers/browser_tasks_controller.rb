class BrowserTasksController < ApplicationController
  before_action :set_task, only: [:show, :kickoff, :complete, :cancel, :humanize]

  def index
    if params[:project_id]
      @project = find_project(params[:project_id])
      @tasks = @project.browser_tasks.recent
    else
      @project = Project.find_by(slug: "general")
      @tasks = BrowserTask.recent.includes(:project)
    end
  end

  def show
    @project = @task.project
    @messages = @task.browser_messages.to_a
  end

  def new
    @project = find_project(params[:project_id])
    @task = @project.browser_tasks.new(priority: "normal")
  end

  def create
    @project = find_project(params[:project_id])
    @task = @project.browser_tasks.new(task_params)
    @task.source = "web"
    if @task.save
      seed_instruction_message(@task)
      redirect_to browser_task_path(@task), notice: "Instruction queued. Kick it off when you're ready."
    else
      render :new, status: :unprocessable_entity
    end
  end

  # "Kick off" — release a queued ticket to Claude-in-Chrome.
  def kickoff
    @task.touch_activity!("dispatched")
    @task.browser_messages.create!(role: "system", kind: "note",
      body: "Kicked off — released to Claude-in-Chrome. Paste the hand-off prompt into the Claude for Chrome chat.")
    redirect_to browser_task_path(@task), notice: "Dispatched. Copy the hand-off prompt below into Claude for Chrome."
  end

  def complete
    body = params[:summary].presence || "Closed by user."
    @task.browser_messages.create!(role: "user", kind: "note", body: body)
    @task.touch_activity!("done")
    redirect_to browser_task_path(@task), notice: "Marked done."
  end

  def cancel
    @task.touch_activity!("cancelled")
    redirect_to browser_task_path(@task), notice: "Cancelled."
  end

  # "Humanize" — kick off a background summary of the whole thread in warm,
  # plain English. The job shells out to the local Claude CLI and streams the
  # result back into the bottom-right panel via Turbo. We answer the click
  # immediately with a loading state so the popover never feels stuck.
  def humanize
    HumanizeThreadJob.perform_later(@task.id)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.update(
          "humanize_content_#{@task.id}",
          partial: "browser_tasks/humanize_loading", locals: { task: @task }
        )
      end
      format.html { redirect_to browser_task_path(@task), notice: "Humanizing this thread…" }
    end
  end

  private

  def set_task
    @task = BrowserTask.find(params[:id])
  end

  def find_project(key)
    Project.where(slug: key).or(Project.where(id: key)).first!
  end

  def task_params
    params.require(:browser_task).permit(:title, :instructions, :target_url, :priority, :initiated_by)
  end

  def seed_instruction_message(task)
    return if task.instructions.blank?
    body = task.instructions
    body = "Open #{task.target_url}\n\n#{body}" if task.target_url.present?
    task.browser_messages.create!(role: "user", kind: "instruction", body: body)
  end
end
