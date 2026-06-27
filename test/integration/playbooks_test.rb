require "test_helper"

# End-to-end Playbooks: CRUD, trigger (→ SessionLaunch + pending PlaybookRun),
# schedule (→ AgentSchedule carrying playbook_id), the missing-repo guard, and
# run evaluation.
class PlaybooksTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "PBI", slug: "pbi-#{SecureRandom.hex(3)}", repo_path: "/tmp/pbi")
  end

  test "create then show a playbook" do
    assert_difference -> { Playbook.count }, 1 do
      post project_playbooks_path(@project), params: { playbook: { name: "Sweep", body: "Do it." } }
    end
    pb = Playbook.last
    assert_redirected_to project_playbook_path(@project, pb)
    follow_redirect!
    assert_response :success
    assert_select "h1", /Sweep/
  end

  test "invalid create re-renders with errors" do
    assert_no_difference -> { Playbook.count } do
      post project_playbooks_path(@project), params: { playbook: { name: "", body: "" } }
    end
    assert_response :unprocessable_entity
  end

  test "trigger queues a SessionLaunch and a pending PlaybookRun" do
    pb = @project.playbooks.create!(name: "Sweep", body: "Do it.")
    assert_difference -> { SessionLaunch.count } => 1, -> { PlaybookRun.count } => 1 do
      post trigger_project_playbook_path(@project, pb)
    end
    assert_redirected_to project_playbook_path(@project, pb)
    assert_equal "pending", PlaybookRun.last.result
  end

  test "trigger on a repo-less project hits the missing-repo guard" do
    repoless = Project.create!(name: "NoRepo", slug: "norepo-#{SecureRandom.hex(3)}")
    pb = repoless.playbooks.create!(name: "x", body: "y")
    assert_no_difference -> { SessionLaunch.count } do
      post trigger_project_playbook_path(repoless, pb)
    end
    assert_redirected_to project_playbook_path(repoless, pb)
    follow_redirect!
    assert_match(/No repo path/, flash[:alert].to_s)
  end

  test "schedule creates an AgentSchedule carrying playbook_id" do
    pb = @project.playbooks.create!(name: "Sweep", body: "Do it.")
    assert_difference -> { AgentSchedule.count }, 1 do
      post schedule_project_playbook_path(@project, pb), params: { cron: "0 9 * * *" }
    end
    sched = AgentSchedule.last
    assert_equal pb.id, sched.playbook_id
    assert_equal "0 9 * * *", sched.cron
  end

  test "schedule with a bad cron redirects with an alert" do
    pb = @project.playbooks.create!(name: "Sweep", body: "Do it.")
    assert_no_difference -> { AgentSchedule.count } do
      post schedule_project_playbook_path(@project, pb), params: { cron: "not a cron" }
    end
    follow_redirect!
    assert_match(/Couldn't schedule/, flash[:alert].to_s)
  end

  test "updating a run evaluates it" do
    pb = @project.playbooks.create!(name: "Sweep", body: "Do it.")
    run = pb.playbook_runs.create!(result: "pending")
    patch playbook_run_path(run), params: { playbook_run: { result: "passed", notes: "ok" } }
    assert_redirected_to project_playbook_path(@project, pb)
    run.reload
    assert_equal "passed", run.result
    assert_equal "ok", run.notes
    assert_not_nil run.evaluated_at
  end
end
