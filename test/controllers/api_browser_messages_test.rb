require "test_helper"

class ApiBrowserMessagesTest < ActionDispatch::IntegrationTest
  setup do
    project = Project.create!(name: "Relay", slug: "relay-#{SecureRandom.hex(3)}", repo_path: "/tmp/relay")
    @task = project.browser_tasks.create!(title: "T", instructions: "Do it.")
  end

  test "accepts a known role with payload" do
    post api_v1_browser_task_messages_path(@task),
         params: { role: "browser", kind: "result", body: "done", payload: { a: "1" } }, as: :json
    assert_response :success
    msg = @task.browser_messages.order(:created_at).last
    assert_equal "browser", msg.role
    assert_equal "1", msg.payload["a"]
  end

  test "rejects an unknown role" do
    assert_no_difference -> { BrowserMessage.count } do
      post api_v1_browser_task_messages_path(@task), params: { role: "admin", body: "x" }, as: :json
    end
    assert_response :unprocessable_entity
  end
end
