require "test_helper"

# Launching an agent FROM a board item: the trigger binds the launch to the task
# (so the terminal-transition write-back can post the result back to it) and
# redirects to the task page.
class AgentTriggerOnTaskTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Trigger", slug: "trigger-#{SecureRandom.hex(3)}",
                               repo_path: "/tmp/trigger")
    @agent = Agent.create!(name: "fixer", kind: "agent", scope: "project", project: @project)
    @task  = @project.tasks.create!(title: "Do the thing", description: "details here")
  end

  test "trigger with task_id binds the launch to the task and redirects to it" do
    assert_difference -> { @project.session_launches.count }, 1 do
      post trigger_project_agent_path(@project, @agent),
           params: { task_id: @task.id, agent_id: @agent.id }
    end
    assert_redirected_to project_task_path(@project, @task)

    launch = @project.session_launches.order(:created_at).last
    assert_equal @task.id, launch.task_id
    assert_equal @agent.id, launch.agent_id
    # No explicit objective typed → seeded from the item's title + description.
    assert_includes launch.prompt, "Do the thing"
  end

  test "trigger without a task still launches and redirects to conversations" do
    assert_difference -> { @project.session_launches.count }, 1 do
      post trigger_project_agent_path(@project, @agent), params: { agent_id: @agent.id }
    end
    launch = @project.session_launches.order(:created_at).last
    assert_nil launch.task_id
    assert_redirected_to project_conversations_path(@project)
  end
end
