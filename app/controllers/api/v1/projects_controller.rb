module Api
  module V1
    class ProjectsController < BaseController
      def index
        render json: Project.order(:name).map { |p| serialize(p) }
      end

      def show
        find_project!
        render json: serialize(@project, detailed: true)
      end

      # Upsert by slug so Claude CLI can call this idempotently from any project directory.
      def create
        slug = params.dig(:project, :slug) || params[:slug]
        attrs = project_params
        # A worktree is not a project of its own: an upsert from inside one lands
        # on the parent repo's project and never renames or re-points it.
        if Project.worktree_path?(attrs[:repo_path]) && (parent = Project.for_repo_path(attrs[:repo_path]))
          return render json: serialize(parent, detailed: true), status: :ok
        end

        attrs = attrs.merge(repo_path: Project.canonical_repo_path(attrs[:repo_path])) if attrs[:repo_path].present?
        project = Project.find_or_initialize_by(slug: slug) if slug.present?
        project ||= Project.new
        project.assign_attributes(attrs)
        project.save!
        render json: serialize(project, detailed: true), status: project.previously_new_record? ? :created : :ok
      end

      def update
        find_project!
        @project.update!(project_params)
        render json: serialize(@project, detailed: true)
      end

      private

      def project_params
        params.require(:project).permit(:name, :slug, :description, :repo_path, :default_base_url)
      rescue ActionController::ParameterMissing
        params.permit(:name, :slug, :description, :repo_path, :default_base_url)
      end

      def serialize(project, detailed: false)
        data = {
          id: project.id, slug: project.slug, name: project.name,
          description: project.description, repo_path: project.repo_path,
          default_base_url: project.default_base_url,
          rollup: project.rollup,
          urls: {
            web: "#{base_url}/projects/#{project.slug}",
            api: "#{base_url}/api/v1/projects/#{project.slug}"
          }
        }
        if detailed
          data[:environments] = project.environments.order(:name).map { |e| { id: e.id, name: e.name, base_url: e.base_url } }
          data[:tasks] = project.tasks.recent.limit(50).map { |t| { id: t.id, title: t.title, status: t.status, priority: t.priority } }
          data[:test_plans] = project.test_plans.order(created_at: :desc).limit(20).map { |p| { id: p.id, title: p.title, status: p.status } }
        end
        data
      end
    end
  end
end
