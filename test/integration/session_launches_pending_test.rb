require "test_helper"

# The host launcher daemon polls GET /api/v1/session_launches/pending and spawns
# each one. daemon_view must only reference real columns/methods — a stray
# attribute (e.g. a non-existent `source`) 500s the poll and stalls the whole
# pipeline, which has no other test coverage.
class SessionLaunchesPendingTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "SL", slug: "sl-#{SecureRandom.hex(3)}", repo_path: "/tmp/sl")
  end

  test "pending returns queued launches with the daemon fields (no 500)" do
    launch = @project.session_launches.create!(
      prompt: "/board-plan x", status: "pending", repo_path: "/tmp/sl",
      session_id: SecureRandom.uuid, pipeline_step: "planning",
      resume_of_session_id: nil
    )

    get "/api/v1/session_launches/pending"
    assert_response :success
    body = JSON.parse(response.body)
    row = body.find { |h| h["id"] == launch.id }
    assert row, "the pending launch is listed"
    assert row.key?("resume_of_session_id"), "daemon_view exposes resume_of_session_id"
    assert_equal launch.session_id, row["session_id"]
  end

  test "pending carries resume_of_session_id for a resume launch" do
    @project.session_launches.create!(
      prompt: "(resume)", status: "pending", repo_path: "/tmp/sl",
      session_id: SecureRandom.uuid, resume_of_session_id: "orig-session-123"
    )
    get "/api/v1/session_launches/pending"
    assert_response :success
    row = JSON.parse(response.body).find { |h| h["resume_of_session_id"] == "orig-session-123" }
    assert row, "resume launch exposes the session to resume"
  end
end
