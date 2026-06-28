require "test_helper"

# The ticket page is meant to be a durable, reviewable record of an autopilot
# run: it surfaces the plan, the agent role/status, a live-session link, and the
# append-only activity/decisions worklog, and refreshes live while worked.
class TaskActivityLogTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Activity", slug: "activity-#{SecureRandom.hex(3)}",
                               repo_path: "/tmp/activity")
    @task = @project.tasks.create!(
      title: "Surface autopilot direction", item_type: "feature",
      board_state: "in_progress", agent_role: "engineering",
      plan: "## Goal\nMake the ticket reviewable.", plan_updated_at: Time.current,
      agent_notes: "Branching off main; assuming X."
    )
  end

  test "ticket renders the plan, role, status and agent notes" do
    get project_task_path(@project, @task)
    assert_response :success
    assert_select "section", text: /Plan & direction/
    assert_match "Make the ticket reviewable.", response.body
    assert_match "Engineering", response.body
    assert_match "Latest agent status", response.body
    assert_match "Branching off main; assuming X.", response.body
  end

  test "ticket subscribes to the live activity stream" do
    get project_task_path(@project, @task)
    assert_response :success
    assert_select "turbo-cable-stream-source"
  end

  test "ticket shows a watch-live-session link when a conversation is present" do
    convo = Conversation.create!(session_id: SecureRandom.uuid, project: @project, title: "live run")
    @task.update!(last_conversation: convo)
    get project_task_path(@project, @task)
    assert_response :success
    assert_select "a[href=?]", conversation_path(convo), text: /Watch live session/
  end

  test "ticket renders the activity & decisions worklog with posted comments" do
    @task.comments.create!(author: "engineer", body: "Direction: touch the show view.")
    get project_task_path(@project, @task)
    assert_response :success
    assert_select "section", text: /Activity & decisions log/
    assert_match "Direction: touch the show view.", response.body
    assert_match "engineer", response.body
  end

  test "a planless item falls back gracefully" do
    @task.update!(plan: nil, agent_notes: nil, plan_updated_at: nil)
    get project_task_path(@project, @task)
    assert_response :success
    assert_match "No plan yet", response.body
  end
end
