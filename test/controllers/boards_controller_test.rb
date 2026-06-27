require "test_helper"

class BoardsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "BC", slug: "bc-#{SecureRandom.hex(3)}", repo_path: "/tmp/bc")
  end

  def item(title, state)
    @project.tasks.create!(title: title, item_type: "task", board_state: state)
  end

  test "reorder stamps position only on the posted (single-group) ids, leaving other groups NULL" do
    a1 = item("Pending A1", "pending")
    a2 = item("Pending A2", "pending")
    b1 = item("Planned B1", "planned")

    # A drag inside the pending group posts only the pending ids, reordered.
    post board_reorder_path(@project), params: { order: [a2.id, a1.id] }
    assert_response :ok

    assert_equal 1, a2.reload.position
    assert_equal 2, a1.reload.position
    assert_nil b1.reload.position, "a group the user never touched keeps NULL positions (recency default)"
  end

  test "reorder with moved_id updates board_state and sequences the destination group" do
    moved = item("Was pending", "pending")
    dest_existing = item("Already planned", "planned")

    # Drop `moved` into the planned group; posted ids are the planned group's new order.
    post board_reorder_path(@project),
         params: { order: [moved.id, dest_existing.id], moved_id: moved.id, moved_state: "planned" }
    assert_response :ok

    assert_equal "planned", moved.reload.board_state, "cross-group drop updates board_state"
    assert_equal 1, moved.position
    assert_equal 2, dest_existing.reload.position
  end
end
