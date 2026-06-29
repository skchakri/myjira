require "test_helper"

# POST /api/v1/agent_events — Claude Code HTTP hook receiver.
# Validates that lifecycle events from board sessions update the worklog,
# SubagentStop returns block decisions when the task is waiting, and unknown
# session IDs are silently no-oped (fail-open).
class AgentEventsTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(
      name: "Hook Test", slug: "hook-test-#{SecureRandom.hex(3)}", repo_path: "/tmp/hook-test"
    )
    @task = @project.tasks.create!(title: "Hook task", board_state: "in_progress")
    @launch = @project.session_launches.create!(
      session_id: SecureRandom.uuid,
      prompt: "/board-engineer #{@task.id} #{@project.slug}",
      repo_path: "/tmp/hook-test",
      task: @task,
      pipeline_step: "engineering"
    )
    Conversation.create!(session_id: @launch.session_id, project: @project,
                         title: "Test", source: "board",
                         started_at: Time.current, last_message_at: Time.current)
    @launch.update!(conversation: Conversation.find_by(session_id: @launch.session_id))
  end

  test "Stop event creates a worklog entry on the task" do
    payload = {
      session_id: @launch.session_id,
      hook_event_type: "Stop",
      usage: { input_tokens: 1000, output_tokens: 500 }
    }
    assert_difference -> { @task.worklog_events.count } do
      post "/api/v1/agent_events", params: payload, as: :json
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal({}, body)
    event = @task.worklog_events.last
    assert_match(/Stop/, event.label)
    assert_match(/in=1000/, event.label)
  end

  test "SubagentStop on an in_progress task logs but does not block" do
    payload = {
      session_id: @launch.session_id,
      hook_event_type: "SubagentStop",
      usage: { output_tokens: 200 }
    }
    post "/api/v1/agent_events", params: payload, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_nil body["decision"], "should not block a non-waiting task"
  end

  test "SubagentStop on a waiting task returns block decision" do
    @task.update!(board_state: "waiting", agent_notes: "Blocked on dangerous command")
    payload = {
      session_id: @launch.session_id,
      hook_event_type: "SubagentStop",
      usage: {}
    }
    post "/api/v1/agent_events", params: payload, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "block", body["decision"]
    assert body["additionalContext"].present?
  end

  test "PostToolUse Bash event logs an activity entry" do
    payload = {
      session_id: @launch.session_id,
      hook_event_type: "PostToolUse",
      tool_name: "Bash",
      tool_input: { command: "bin/rails test" }
    }
    assert_difference -> { @task.worklog_events.count } do
      post "/api/v1/agent_events", params: payload, as: :json
    end
    assert_response :success
    event = @task.worklog_events.last
    assert_match(/bin\/rails test/, event.label)
  end

  test "PostToolUse for a non-Bash tool is silently ignored" do
    payload = {
      session_id: @launch.session_id,
      hook_event_type: "PostToolUse",
      tool_name: "Read",
      tool_input: { file_path: "/tmp/foo" }
    }
    assert_no_difference -> { @task.worklog_events.count } do
      post "/api/v1/agent_events", params: payload, as: :json
    end
    assert_response :success
  end

  test "unknown session_id is a silent no-op returning 200" do
    payload = {
      session_id: SecureRandom.uuid,
      hook_event_type: "Stop",
      usage: { output_tokens: 100 }
    }
    assert_no_difference -> { @task.worklog_events.count } do
      post "/api/v1/agent_events", params: payload, as: :json
    end
    assert_response :success
    assert_equal({}, JSON.parse(response.body))
  end

  test "GET sessions/:session_id/task returns task info" do
    get "/api/v1/sessions/#{@launch.session_id}/task"
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @task.id, body["task_id"]
    assert_equal "in_progress", body["board_state"]
    assert_equal @project.slug, body["project_slug"]
  end

  test "GET sessions/:session_id/task returns 404 for unknown session" do
    get "/api/v1/sessions/#{SecureRandom.uuid}/task"
    assert_response :not_found
  end
end
