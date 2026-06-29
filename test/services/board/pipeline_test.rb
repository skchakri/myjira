require "test_helper"

class Board::PipelineTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "PL", slug: "pl-#{SecureRandom.hex(3)}", repo_path: "/tmp/pl")
  end

  test "launch_step! stamps the auto-routed model onto the created SessionLaunch" do
    # short ask + answer step → haiku
    item = @project.tasks.create!(title: "Q", item_type: "ask", description: "How?", board_state: "planned")
    launch = Board::Pipeline.launch_step!(item, step: "answer")
    assert_equal "haiku", launch.model
  end

  test "launch_step! routes a typical engineering item to sonnet" do
    item = @project.tasks.create!(title: "Feature", item_type: "feature", description: "Add a button",
                                  board_state: "planned")
    launch = Board::Pipeline.launch_step!(item, step: "engineering")
    assert_equal "sonnet", launch.model
  end

  test "launch_step! escalates an urgent item to opus" do
    item = @project.tasks.create!(title: "Fire", item_type: "issue", priority: "urgent", board_state: "planned")
    launch = Board::Pipeline.launch_step!(item, step: "debugger")
    assert_equal "opus", launch.model
  end

  test "launch_step! emits a model.routed worklog node" do
    item = @project.tasks.create!(title: "Feature", item_type: "feature", board_state: "planned")
    launch = Board::Pipeline.launch_step!(item, step: "engineering")
    node = launch.worklog_events.find_by(name: "model.routed")
    assert node, "a model.routed worklog node is persisted"
    assert_equal "Auto-routed model → sonnet", node.label
  end
end
