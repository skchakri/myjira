module Api
  module V1
    class EnvironmentsController < BaseController
      before_action :find_project!

      def index
        render json: @project.environments.order(:name).map { |e| serialize(e) }
      end

      def show
        render json: serialize(@project.environments.find(params[:id]))
      end

      def create
        env = @project.environments.find_or_initialize_by(name: params[:name] || params.dig(:environment, :name))
        env.assign_attributes(env_params)
        env.save!
        render json: serialize(env), status: env.previously_new_record? ? :created : :ok
      end

      def update
        env = @project.environments.find(params[:id])
        env.update!(env_params)
        render json: serialize(env)
      end

      private

      def env_params
        raw = params[:environment] || params
        raw.permit(:name, :base_url, :notes)
      end

      def serialize(env)
        { id: env.id, name: env.name, base_url: env.base_url, notes: env.notes, project_slug: @project.slug }
      end
    end
  end
end
