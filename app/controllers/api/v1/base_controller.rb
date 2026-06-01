module Api
  module V1
    class BaseController < ActionController::API
      rescue_from ActiveRecord::RecordNotFound, with: :not_found
      rescue_from ActiveRecord::RecordInvalid,  with: :unprocessable

      private

      def not_found(e)
        render json: { error: "not_found", message: e.message }, status: :not_found
      end

      def unprocessable(e)
        render json: { error: "invalid", message: e.message, details: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      def find_project!
        key = params[:project_id] || params[:id]
        @project = Project.where(slug: key).or(Project.where(id: key)).first!
      end

      def base_url
        request.base_url
      end

      def next_steps_for(resource)
        # Hints that tell Claude CLI what to call next after any create/update.
        case resource
        when Task
          {
            create_test_plan: "POST #{base_url}/api/v1/projects/#{resource.project.slug}/test_plans",
            update_status:    "PATCH #{base_url}/api/v1/projects/#{resource.project.slug}/tasks/#{resource.id}",
            report_gap:       "POST #{base_url}/api/v1/projects/#{resource.project.slug}/tasks/#{resource.id}/follow_ups"
          }
        when TestPlan
          {
            add_cases:        "POST #{base_url}/api/v1/projects/#{resource.project.slug}/test_plans/#{resource.id}/test_cases/bulk",
            start_run:        "POST #{base_url}/api/v1/projects/#{resource.project.slug}/test_plans/#{resource.id}/test_runs",
            view:             "#{base_url}/projects/#{resource.project.slug}/test_plans/#{resource.id}"
          }
        when TestRun
          {
            update_result:    "PATCH #{base_url}/api/v1/test_runs/#{resource.id}/results/{test_case_id}",
            complete:         "PATCH #{base_url}/api/v1/test_runs/#{resource.id}/complete",
            view:             "#{base_url}/test_runs/#{resource.id}"
          }
        when BrowserTask
          {
            kickoff:      "POST #{base_url}/api/v1/browser_tasks/#{resource.id}/kickoff",
            post_message: "POST #{base_url}/api/v1/browser_tasks/#{resource.id}/messages",
            watch:        "GET #{base_url}/api/v1/browser_tasks/#{resource.id}?wait=25&since={iso8601_cursor}",
            complete:     "PATCH #{base_url}/api/v1/browser_tasks/#{resource.id}/complete",
            view:         "#{base_url}/browser_tasks/#{resource.id}"
          }
        else
          {}
        end
      end
    end
  end
end
