require "test_helper"

class ProjectsBlinkTest < ActionDispatch::IntegrationTest
  test "a project needing attention pulses with a needs-you badge on the index" do
    project = Project.create!(name: "Blinky", slug: "blinky-#{SecureRandom.hex(3)}", repo_path: "/tmp/blinky")
    project.tasks.create!(title: "Approve me", item_type: "feature", board_state: "waiting",
                          wait_reason: "awaiting_approval", plan: "p")
    get projects_path
    assert_response :success
    assert_select "#project_card_#{project.id}"
    assert_match "Needs you", response.body
  end
end
