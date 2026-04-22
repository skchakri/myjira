class EnvironmentsController < ApplicationController
  before_action :set_project
  before_action :set_environment, only: [:show, :edit, :update, :destroy]

  def show; end

  def new
    @environment = @project.environments.new
  end

  def create
    @environment = @project.environments.new(env_params)
    if @environment.save
      redirect_to @project, notice: "Environment created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @environment.update(env_params)
      redirect_to @project, notice: "Environment updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @environment.destroy
    redirect_to @project, notice: "Environment removed."
  end

  private

  def set_project
    @project = Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
  end

  def set_environment
    @environment = @project.environments.find(params[:id])
  end

  def env_params
    params.require(:environment).permit(:name, :base_url, :notes)
  end
end
