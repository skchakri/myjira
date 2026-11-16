# Per-project Documents — plans, specs, reports and notes. CLI sessions file
# them through the API (or `relay doc`); this is the reading + editing side.
class DocumentsController < ApplicationController
  before_action :set_project
  before_action :set_document, only: [:show, :edit, :update, :destroy]

  def index
    @kind = params[:kind].presence_in(Document::KINDS)
    scope = @project.documents.recent
    @counts = @project.documents.group(:kind).count
    @documents = @kind ? scope.where(kind: @kind) : scope
  end

  def show
    @revisions = @document.revisions.select(:id, :version, :title, :author, :created_at).to_a
    if params[:version].present? && params[:version].to_i != @document.version
      @revision = @document.revisions.find_by!(version: params[:version].to_i)
    end
  end

  def new
    @document = @project.documents.new(kind: params[:kind].presence_in(Document::KINDS) || "note")
  end

  def create
    @document = @project.documents.new(document_params.merge(author: "web"))
    if @document.save
      redirect_to project_document_path(@project, @document), notice: "Document created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @document.update(document_params.merge(author: "web"))
      redirect_to project_document_path(@project, @document), notice: "Saved as version #{@document.version}."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @document.destroy!
    redirect_to project_documents_path(@project), notice: "Deleted “#{@document.title}”."
  end

  private

  def set_project
    @project = Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
  end

  def set_document
    @document = @project.documents.find_by!(slug: params[:id])
  end

  def document_params
    params.require(:document).permit(:title, :kind, :body)
  end
end
