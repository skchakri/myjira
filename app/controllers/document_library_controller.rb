# Cross-project Documents: every plan, spec, report and note, newest first.
# The per-project list, reader and editor stay in DocumentsController.
class DocumentLibraryController < ApplicationController
  PER_PAGE = 30

  def index
    @kind = params[:kind].presence_in(Document::KINDS)
    @project = Project.find_by(slug: params[:project].to_s) if params[:project].present?
    scope = Document.all
    scope = scope.where(project: @project) if @project
    @counts = scope.group(:kind).count
    scope = scope.where(kind: @kind) if @kind
    @page = [params[:page].to_i, 1].max
    rows = scope.recent.includes(:project).offset((@page - 1) * PER_PAGE).limit(PER_PAGE + 1).to_a
    @more = rows.size > PER_PAGE
    @documents = rows.first(PER_PAGE)
    @projects = Project.where(id: Document.select(:project_id)).order(:name)
  end
end
