class TestCasesController < ApplicationController
  before_action :set_project
  before_action :set_plan
  before_action :set_case, only: [:show, :edit, :update, :destroy]

  def new
    @case = @plan.test_cases.new
  end

  def create
    @case = @plan.test_cases.new(case_params)
    if @case.save
      redirect_to [@project, @plan], notice: "Test case added."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @case.update(case_params)
      redirect_to [@project, @plan], notice: "Test case updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @case.destroy
    redirect_to [@project, @plan], notice: "Test case removed."
  end

  private

  def set_project
    @project = Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
  end

  def set_plan
    @plan = @project.test_plans.find(params[:test_plan_id])
  end

  def set_case
    @case = @plan.test_cases.find(params[:id])
  end

  def case_params
    params.require(:test_case).permit(:title, :steps, :expected_result, :api_call, :task_id, :position, :notes)
  end
end
