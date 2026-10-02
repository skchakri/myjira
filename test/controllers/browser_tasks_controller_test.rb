require "test_helper"

class BrowserTasksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Relay", slug: "relay-#{SecureRandom.hex(3)}", repo_path: "/tmp/relay")
    @task = @project.browser_tasks.create!(title: "Grab affiliate IDs", instructions: "Open the site.")
  end

  test "show offers copy prompt and run in chrome under the thread" do
    get browser_task_path(@task)
    assert_response :success
    assert_select "button[data-clipboard-text-param]", text: /Copy prompt/
    assert_select "form[action='#{run_in_chrome_browser_task_path(@task)}']"
  end

  test "run_in_chrome queues a --chrome launch in the originating CLI's cwd" do
    convo = @project.conversations.create!(session_id: SecureRandom.uuid, cwd: "/tmp/origin",
                                           started_at: Time.current, last_message_at: Time.current)
    @task.update!(conversation: convo)

    assert_difference -> { SessionLaunch.count }, 1 do
      post run_in_chrome_browser_task_path(@task)
    end
    assert_redirected_to browser_task_path(@task)

    launch = SessionLaunch.order(:created_at).last
    assert launch.chrome
    assert_equal "/tmp/origin", launch.repo_path
    assert_equal "auto", launch.permission_mode
    assert_includes launch.prompt, @task.id
    assert_includes launch.prompt, "claude-in-chrome"
    assert_equal "dispatched", @task.reload.status
  end

  test "run_in_chrome falls back to the ticket project's repo" do
    post run_in_chrome_browser_task_path(@task)
    assert_equal "/tmp/relay", SessionLaunch.order(:created_at).last.repo_path
  end

  test "a second click while a session is running doesn't launch a duplicate" do
    post run_in_chrome_browser_task_path(@task)
    assert_no_difference -> { SessionLaunch.count } do
      post run_in_chrome_browser_task_path(@task)
    end
    assert_equal @task, SessionLaunch.order(:created_at).last.browser_task
  end

  test "show swaps the button for a running state once launched" do
    post run_in_chrome_browser_task_path(@task)
    get browser_task_path(@task)
    assert_select "form[action='#{run_in_chrome_browser_task_path(@task)}']", count: 0
    assert_select "[data-controller='refresh-soon']", text: /Starting Claude/

    SessionLaunch.last.update!(status: "launched", launched_at: Time.current, tmux_target: "myjira:general-abc123")
    get browser_task_path(@task)
    assert_select "a[href*='general-abc123']", text: /Running in Chrome/
  end
end
