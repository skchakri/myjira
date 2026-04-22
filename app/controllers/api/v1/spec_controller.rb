module Api
  module V1
    class SpecController < BaseController
      # A single endpoint Claude CLI can hit to learn the full API surface.
      def show
        b = base_url
        render json: {
          service: "myjira",
          no_auth: true,
          endpoints: {
            create_or_upsert_project: "POST #{b}/api/v1/projects  { slug, name, description?, repo_path?, default_base_url? }",
            list_projects: "GET  #{b}/api/v1/projects",
            show_project:  "GET  #{b}/api/v1/projects/:slug",

            create_environment: "POST #{b}/api/v1/projects/:slug/environments  { name, base_url?, notes? }",

            create_task:   "POST #{b}/api/v1/projects/:slug/tasks  { title, description?, implementation_notes?, environment?, external_ref?, status?, priority? }",
            update_task:   "PATCH #{b}/api/v1/projects/:slug/tasks/:id  { status?, implementation_notes?, ... }",
            list_tasks:    "GET  #{b}/api/v1/projects/:slug/tasks",

            create_test_plan: "POST #{b}/api/v1/projects/:slug/test_plans  { title, description?, task_ids: [ ... ], status? }",
            bulk_test_cases:  "POST #{b}/api/v1/projects/:slug/test_plans/:plan_id/test_cases/bulk  { cases: [ { title, steps, expected_result, api_call?, task_id? }, ... ] }",

            start_test_run:   "POST #{b}/api/v1/projects/:slug/test_plans/:plan_id/test_runs  { environment_id?, initiated_by? }",
            update_result:    "PATCH #{b}/api/v1/test_runs/:run_id/results/:test_case_id  { status: pass|fail|blocked|skipped, actual_result?, notes?, screenshot_url? }",
            complete_run:     "PATCH #{b}/api/v1/test_runs/:run_id/complete  { summary? }",

            report_follow_up: "POST #{b}/api/v1/projects/:slug/follow_ups  { title, description?, severity?, kind?, task_id?, test_result_id? }",
            list_follow_ups:  "GET  #{b}/api/v1/projects/:slug/follow_ups"
          },
          enums: {
            task_status:     Task::STATUSES,
            task_priority:   Task::PRIORITIES,
            run_status:      TestRun::STATUSES,
            result_status:   TestResult::STATUSES,
            follow_up_kind:  FollowUpTask::KINDS,
            follow_up_sev:   FollowUpTask::SEVERITIES,
            follow_up_state: FollowUpTask::STATUSES
          }
        }
      end
    end
  end
end
