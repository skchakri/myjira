class ProjectsController < ApplicationController
  before_action :set_project, only: [:show, :edit, :update, :destroy, :color]

  def index
    @projects = Project.clients.order(:name)
  end

  def show
    @tasks = @project.tasks.recent.limit(100)
    @plans = @project.test_plans.order(created_at: :desc).limit(25)
    @follow_ups = @project.follow_up_tasks.where(status: %w[open in_progress]).order(created_at: :desc).limit(25)
  end

  def new
    @project = Project.new
  end

  def create
    @project = Project.new(project_params)
    if @project.save
      redirect_to @project, notice: "Project created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @project.update(project_params)
      redirect_to @project, notice: "Project updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @project.destroy
    redirect_to projects_path, notice: "Project deleted."
  end

  # Recolor a folder from the conversation cards' gear menu. Accepts a hex value
  # or blank (reset to the palette default). Returns to wherever it was called.
  def color
    value = params[:color].to_s
    @project.update_column(:color, value.match?(/\A#[0-9A-Fa-f]{6}\z/) ? value.downcase : nil)
    redirect_back fallback_location: conversations_path
  end

  private

  def set_project
    @project = Project.where(slug: params[:id]).or(Project.where(id: params[:id])).first!
  end

  def project_params
    params.require(:project).permit(:name, :slug, :description, :repo_path, :default_base_url)
  end
end
