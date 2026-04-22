module Api
  module V1
    class ClientsController < BaseController
      include ClientOverview

      def index
        projects = Project.order(:name)
        render json: {
          clients: projects.map { |p| client_summary(p) },
          url_template: "#{base_url}/c/{slug}",
          api_template: "#{base_url}/api/v1/clients/{slug}"
        }
      end

      def show
        project = find_or_provision_project(params[:slug])
        overview = build_client_overview(project)
        render json: serialize_overview(project, overview)
      end

      private

      def client_summary(project)
        overview = build_client_overview(project)
        {
          slug: project.slug,
          name: project.name,
          url:      "#{base_url}/c/#{project.slug}",
          api_url:  "#{base_url}/api/v1/clients/#{project.slug}",
          stats: overview[:stats]
        }
      end

      def serialize_overview(project, overview)
        {
          client: {
            slug: project.slug,
            name: project.name,
            description: project.description,
            url:     "#{base_url}/c/#{project.slug}",
            web_url: "#{base_url}/projects/#{project.slug}"
          },
          stats: overview[:stats],
          test_plans: overview[:plans].map { |p|
            run = overview[:latest_runs][p]
            {
              id:     p.id,
              title:  p.title,
              status: p.status,
              cases:  p.test_cases.size,
              tasks:  p.tasks.size,
              url:    "#{base_url}/projects/#{project.slug}/test_plans/#{p.id}",
              latest_run: run && {
                id:       run.id,
                status:   run.status,
                started_at: run.started_at,
                total:    run.total_cases,
                passed:   run.passed_count,
                failed:   run.failed_count,
                blocked:  run.blocked_count,
                skipped:  run.skipped_count,
                percent:  run.progress[:percent],
                url:      "#{base_url}/test_runs/#{run.id}"
              }
            }
          },
          open_gaps: overview[:open_gaps].map { |g|
            {
              id: g.id,
              title: g.title,
              kind: g.kind,
              severity: g.severity,
              status: g.status,
              task_id: g.task_id,
              test_result_id: g.test_result_id,
              created_at: g.created_at,
              url: "#{base_url}/projects/#{project.slug}/follow_up_tasks/#{g.id}/edit"
            }
          }
        }
      end
    end
  end
end
