require "test_helper"

# The agent-facing task API exposes `labels` (a routing primitive) on read and
# accepts them as a JSON array or a comma string on create/update.
class TaskLabelsApiTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "API Labels", slug: "api-labels-#{SecureRandom.hex(3)}",
                               repo_path: "/tmp/api-labels")
    @item = @project.tasks.create!(title: "Item", item_type: "task", board_state: "pending")
  end

  test "POST creates a task with a labels array, normalized" do
    post "/api/v1/projects/#{@project.slug}/tasks",
         params: { task: { title: "New", labels: ["Needs-Human", "flaky", "FLAKY"] } }, as: :json
    assert_response :success
    task = @project.tasks.find_by(title: "New")
    assert_equal ["needs-human", "flaky"], task.labels
    assert_equal ["needs-human", "flaky"], response.parsed_body["labels"]
  end

  test "PATCH updates labels and they serialize back" do
    patch "/api/v1/projects/#{@project.slug}/tasks/#{@item.id}",
          params: { task: { labels: ["agent-authored", "flaky"] } }, as: :json
    assert_response :success
    assert_equal ["agent-authored", "flaky"], @item.reload.labels
    assert_equal ["agent-authored", "flaky"], response.parsed_body["labels"]
  end

  test "GET serializes labels on the list and detail payloads" do
    @item.update!(labels: ["needs-human"])
    get "/api/v1/projects/#{@project.slug}/tasks", as: :json
    assert_response :success
    row = response.parsed_body.find { |t| t["id"] == @item.id }
    assert_equal ["needs-human"], row["labels"]

    get "/api/v1/projects/#{@project.slug}/tasks/#{@item.id}", as: :json
    assert_response :success
    assert_equal ["needs-human"], response.parsed_body["labels"]
  end
end
