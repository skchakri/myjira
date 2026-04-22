class ClientsController < ApplicationController
  include ClientOverview

  def index
    @projects = Project.order(:name)
    @summaries = @projects.map { |p| [ p, build_client_overview(p)[:stats] ] }
  end

  def show
    @project = find_or_provision_project(params[:slug])
    overview = build_client_overview(@project)
    @plans        = overview[:plans]
    @latest_runs  = overview[:latest_runs]
    @open_gaps    = overview[:open_gaps]
    @stats        = overview[:stats]
  end
end
