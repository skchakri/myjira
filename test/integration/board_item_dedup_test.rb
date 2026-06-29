require "test_helper"

# The task-create API collapses an exact restatement of an open board item to the
# existing row (returning deduped: true) instead of appending another near-identical
# pending item — the guard against the uncoordinated producers that flood the board.
class BoardItemDedupTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "DD", slug: "dd-#{SecureRandom.hex(3)}", repo_path: "/tmp/dd")
  end

  def create_item(title)
    post "/api/v1/projects/#{@project.slug}/tasks",
         params: { task: { title: title, item_type: "issue", priority: "normal" } }, as: :json
  end

  test "an exact restatement of an open item is deduped, not created again" do
    create_item("Investigate autopilot running three board items at once")
    assert_response :created
    first_id = JSON.parse(response.body)["id"]

    assert_no_difference -> { @project.tasks.count } do
      create_item("  investigate AUTOPILOT running three board-items at once!! ")
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["deduped"]
    assert_equal first_id, body["id"], "returns the existing item"
  end

  test "a genuinely new title still creates a fresh item" do
    create_item("Add server-side dedup for board item creation")
    assert_response :created
    assert_difference -> { @project.tasks.count }, 1 do
      create_item("Tighten autopilot one-at-a-time guard")
    end
    assert_response :created
  end

  test "a done item does not block re-filing the same title" do
    create_item("Fix PendingMigrationError for worklog_events")
    @project.tasks.update_all(board_state: "done")
    assert_difference -> { @project.tasks.count }, 1 do
      create_item("Fix PendingMigrationError for worklog_events")
    end
    assert_response :created
  end
end
