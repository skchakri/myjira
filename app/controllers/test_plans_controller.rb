class TestPlansController < ApplicationController
  before_action :set_project
  before_action :set_plan, only: [:show, :edit, :update, :destroy]

  def index
    @plans = @project.test_plans.order(created_at: :desc)
  end

  def show
    @cases = @plan.test_cases.order(:position)
    @runs = @plan.test_runs.order(started_at: :desc)
  end

  def new
    @plan = @project.test_plans.new
    @tasks = @project.tasks.recent.limit(200)
  end

  def create
    @plan = @project.test_plans.new(plan_params)
    task_ids = Array(params.dig(:test_plan, :task_ids))
    if @plan.save
      @project.tasks.where(id: task_ids).each { |t| @plan.test_plan_tasks.find_or_create_by!(task: t) }
      redirect_to [@project, @plan], notice: "Test plan created. Add test cases next."
    else
      @tasks = @project.tasks.recent.limit(200)
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @tasks = @project.tasks.recent.limit(200)
  end

  def update
    if @plan.update(plan_params)
      task_ids = Array(params.dig(:test_plan, :task_ids))
      if task_ids.any?
        @plan.test_plan_tasks.destroy_all
        @project.tasks.where(id: task_ids).each { |t| @plan.test_plan_tasks.find_or_create_by!(task: t) }
      end
      redirect_to [@project, @plan], notice: "Test plan updated."
    else
      @tasks = @project.tasks.recent.limit(200)
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @plan.destroy
    redirect_to @project, notice: "Test plan deleted."
  end

  private

  def set_project
    @project = Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
  end

  def set_plan
    @plan = @project.test_plans.find(params[:id])
  end

  def plan_params
    params.require(:test_plan).permit(:title, :description, :status)
  end
end
