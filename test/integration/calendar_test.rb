require "test_helper"

class CalendarTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "CalI", slug: "cali-#{SecureRandom.hex(3)}", repo_path: "/tmp/cali")
  end

  test "api sync then the month grid shows the job" do
    post "/api/v1/calendar_jobs/sync", params: {
      source: "system_cron",
      jobs: [{ external_id: "o", title: "Downloads organizer", cron: "0 7 * * * America/Denver", meta: { tz: "America/Denver" } }]
    }, as: :json
    assert_response :success
    assert_equal 1, response.parsed_body["synced"]

    get calendar_path
    assert_response :success
    assert_select ".cal-chip", text: /Downloads organizer/
  end

  test "api sync rejects an unknown source" do
    post "/api/v1/calendar_jobs/sync", params: { source: "suggested", jobs: [] }, as: :json
    assert_response :unprocessable_entity
  end

  test "suggestions upsert and keep their promotion" do
    payload = { jobs: [{ external_id: "deploy", title: "Deploy", command: "ship", cron: "0 9 * * 1", project: @project.slug, evidence: "often" }] }
    post "/api/v1/calendar_jobs/suggestions", params: payload, as: :json
    job = CalendarJob.find_by!(source: "suggested", external_id: "deploy")
    post promote_calendar_job_path(job)
    assert job.reload.promoted?
    refute job.agent_schedule.enabled?

    post "/api/v1/calendar_jobs/suggestions", params: payload, as: :json
    assert job.reload.promoted?
  end

  test "drawer shows a suggestion with its evidence and schedule form" do
    job = CalendarJob.create!(source: "suggested", external_id: "e", title: "Audit", cron: "0 9 1 * *", evidence: "asked 10 times")
    get calendar_item_path(type: "job", id: job.id)
    assert_response :success
    assert_select "turbo-frame#calendar_drawer"
    assert_match "asked 10 times", response.body
    assert_select "form[action='#{promote_calendar_job_path(job)}']"
  end

  test "dismiss hides a suggestion" do
    job = CalendarJob.create!(source: "suggested", external_id: "z", title: "Nah", cron: "0 9 1 * *")
    post dismiss_calendar_job_path(job)
    assert job.reload.dismissed_at
  end
end
