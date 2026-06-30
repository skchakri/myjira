require "test_helper"

class BoardApprovalGateTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Gate", slug: "gate-#{SecureRandom.hex(3)}", repo_path: "/tmp/g")
    @task = @project.tasks.create!(title: "Build X", item_type: "feature", board_state: "in_progress")
  end

  test "an agent PATCHing planned is gated to waiting:awaiting_approval" do
    patch "/api/v1/projects/#{@project.slug}/tasks/#{@task.id}",
          params: { task: { board_state: "planned", agent_role: "engineering", plan: "## Plan" } }
    assert_response :success
    @task.reload
    assert_equal "waiting", @task.board_state
    assert_equal "awaiting_approval", @task.wait_reason
    assert_equal "engineering", @task.agent_role
    assert_equal "## Plan", @task.plan
  end

  test "an agent can PATCH needs_input with questions" do
    patch "/api/v1/projects/#{@project.slug}/tasks/#{@task.id}",
          params: { task: { board_state: "waiting", wait_reason: "needs_input",
                            pending_questions: [{ id: "q1", q: "Which format?", a: nil }] } }
    assert_response :success
    @task.reload
    assert @task.needs_input?
    assert_equal "Which format?", @task.pending_questions.first["q"]
  end

  test "the gate does not touch in_review or done transitions" do
    patch "/api/v1/projects/#{@project.slug}/tasks/#{@task.id}",
          params: { task: { board_state: "in_review", pr_url: "https://github.com/x/y/pull/1",
                            pr_number: 1, pr_state: "open" } }
    assert_response :success
    assert_equal "in_review", @task.reload.board_state
  end
end
