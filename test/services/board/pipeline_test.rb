require "test_helper"

# The per-item "processing now" indicator only goes live if a board refresh is
# broadcast the moment a launch is queued. Autopilot's daemon path queues steps
# without changing board_state, so Board::Pipeline must broadcast itself. These
# tests pin that every launch path morphs the [project, :board] stream.
class Board::PipelineTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "PL", slug: "pl-#{SecureRandom.hex(3)}", repo_path: "/tmp/pl")
  end

  def task(state:, role: "engineering")
    @project.tasks.create!(title: "t-#{SecureRandom.hex(3)}", board_state: state, agent_role: role)
  end

  # Capture every [project, :board] refresh fired during the block.
  def capture_board_broadcasts
    seen = []
    Turbo::StreamsChannel.stub(:broadcast_refresh_to, ->(target) { seen << target }) do
      yield
    end
    seen
  end

  test "launch_step! broadcasts a board refresh so the indicator appears live" do
    t = task(state: "planned")
    seen = capture_board_broadcasts { Board::Pipeline.launch_step!(t, step: "engineering") }
    assert_includes seen, [@project, :board]
  end

  test "launch_triage! broadcasts a board refresh" do
    t = task(state: "pending")
    seen = capture_board_broadcasts { Board::Pipeline.launch_triage!(t) }
    assert_includes seen, [@project, :board]
  end

  test "launch_resolve_conflicts! broadcasts a board refresh" do
    t = task(state: "in_review")
    seen = capture_board_broadcasts { Board::Pipeline.launch_resolve_conflicts!(t) }
    assert_includes seen, [@project, :board]
  end

  test "launch_review! broadcasts a board refresh" do
    seen = capture_board_broadcasts { Board::Pipeline.launch_review!(@project) }
    assert_includes seen, [@project, :board]
  end

  test "a project with no repo never queues a launch and never broadcasts" do
    no_repo = Project.create!(name: "NR", slug: "nr-#{SecureRandom.hex(3)}", repo_path: nil)
    t = no_repo.tasks.create!(title: "x", board_state: "planned", agent_role: "engineering")
    seen = capture_board_broadcasts { Board::Pipeline.launch_step!(t, step: "engineering") }
    assert_empty seen
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
