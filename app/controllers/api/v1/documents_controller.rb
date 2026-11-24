module Api
  module V1
    # Plans / specs / reports / notes filed by Claude CLI sessions.
    #
    #   POST  /api/v1/projects/:project_id/documents   upsert by slug (derived from title when absent)
    #   POST  /api/v1/documents                        same, project resolved from repo_path (a cwd is fine)
    #   GET   /api/v1/projects/:project_id/documents   list (no bodies); ?kind=plan
    #   GET   /api/v1/projects/:project_id/documents/:id   one document (slug or uuid) with body
    #   PATCH /api/v1/projects/:project_id/documents/:id   update fields
    class DocumentsController < BaseController
      before_action :find_project!, except: [:upsert]
      before_action :find_project_for_upsert!, only: [:upsert]

      def index
        scope = @project.documents.recent
        scope = scope.where(kind: params[:kind]) if params[:kind].present?
        render json: scope.limit(200).map { |d| serialize(d) }
      end

      def show
        render json: serialize(find_document!, body: true)
      end

      def create
        upsert_into(@project)
      end

      def upsert
        upsert_into(@project)
      end

      def update
        doc = find_document!
        doc.update!(document_params)
        render json: serialize(doc, body: true)
      end

      private

      def upsert_into(project)
        attrs = document_params
        slug = Document.slugify(attrs[:slug].presence || attrs[:title])
        doc = project.documents.find_or_initialize_by(slug: slug)
        doc.assign_attributes(attrs.except(:slug))
        doc.save!
        render json: serialize(doc, body: true), status: doc.previously_new_record? ? :created : :ok
      end

      # repo_path may be the repo root or any folder inside it — pick the project
      # whose repo_path is the longest prefix. A project slug works too.
      def find_project_for_upsert!
        raw = params[:document].is_a?(ActionController::Parameters) ? params[:document] : params
        key = params[:project].presence || raw[:project].presence
        return @project = Project.where(slug: key).or(Project.where(id: key)).first! if key

        path = (params[:repo_path].presence || raw[:repo_path]).to_s.chomp("/")
        # Inside an agent worktree: the document belongs to the parent repo's project.
        path = Project.canonical_repo_path(path) if Project.worktree_path?(path)
        @project = Project.where.not(repo_path: [nil, ""]).select { |p|
          root = p.repo_path.chomp("/")
          path == root || path.start_with?("#{root}/")
        }.max_by { |p| p.repo_path.length }
        return if @project

        render json: { error: "not_found",
                       message: "No myjira project has a repo_path matching #{path.inspect}. " \
                                "Pass project=<slug>, or set the project's repo_path." },
               status: :not_found
      end

      def find_document!
        key = params[:id].to_s
        @project.documents.where(slug: key).or(@project.documents.where(id: uuid?(key) ? key : nil)).first!
      end

      def uuid?(s)
        s.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      end

      def document_params
        raw = params[:document].is_a?(ActionController::Parameters) ? params[:document] : params
        raw.permit(:title, :slug, :kind, :body, :source_path, :cli_session_id, :author, :task_id)
      end

      def serialize(doc, body: false)
        data = {
          id: doc.id, slug: doc.slug, title: doc.title, kind: doc.kind, version: doc.version,
          project: doc.project.slug, task_id: doc.task_id, source_path: doc.source_path,
          cli_session_id: doc.cli_session_id, author: doc.author,
          created_at: doc.created_at, updated_at: doc.updated_at,
          urls: {
            web: "#{base_url}/projects/#{doc.project.slug}/documents/#{doc.slug}",
            api: "#{base_url}/api/v1/projects/#{doc.project.slug}/documents/#{doc.slug}"
          }
        }
        data[:body] = doc.body if body
        data
      end
    end
  end
end
