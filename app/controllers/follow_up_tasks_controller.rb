class FollowUpTasksController < ApplicationController
  before_action :set_project

  def index
    @follow_ups = @project.follow_up_tasks.order(created_at: :desc)
  end

  def new
    @task = @project.tasks.find(params[:task_id]) if params[:task_id]
    @follow_up = @project.follow_up_tasks.new(task: @task)
  end

  def create
    @follow_up = @project.follow_up_tasks.new(follow_up_params)
    if @follow_up.save
      redirect_back fallback_location: @project, notice: "Follow-up logged."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @follow_up = @project.follow_up_tasks.find(params[:id])
  end

  def update
    @follow_up = @project.follow_up_tasks.find(params[:id])
    if @follow_up.update(follow_up_params)
      redirect_to project_follow_up_tasks_path(@project), notice: "Follow-up updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @follow_up = @project.follow_up_tasks.find(params[:id])
    @follow_up.destroy
    redirect_to project_follow_up_tasks_path(@project), notice: "Follow-up deleted."
  end

  private

  def set_project
    @project = Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
  end

  def follow_up_params
    params.require(:follow_up_task).permit(:title, :description, :severity, :status, :kind, :task_id, :test_result_id)
  end
end
