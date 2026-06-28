require "test_helper"

class AutopilotOrchestratorTest < ActiveSupport::TestCase
  setup do
    Setting.where(key: "autopilot_stopped").destroy_all
    @project = Project.create!(name: "AP", slug: "ap-#{SecureRandom.hex(3)}", repo_path: "/tmp/ap",
                               autopilot_enabled: true, autopilot_paused: false,
                               autopilot_review_enabled: false)
  end

  test "tick_project skips a project that already has an in_progress item" do
    @project.tasks.create!(title: "Running", item_type: "task", board_state: "in_progress")
    @project.tasks.create!(title: "Next", item_type: "task", board_state: "pending")
    assert_no_difference -> { @project.session_launches.count } do
      Autopilot::Orchestrator.tick_project(@project)
    end
  end

  test "tick_project advances exactly one item when the project is free" do
    @project.tasks.create!(title: "Next", item_type: "task", board_state: "pending")
    assert_difference -> { @project.session_launches.where.not(pipeline_step: nil).count }, 1 do
      Autopilot::Orchestrator.tick_project(@project)
    end
  end

  test "a waiting item neither blocks nor is picked up" do
    @project.tasks.create!(title: "Wait", item_type: "task", board_state: "waiting")
    assert_no_difference -> { @project.session_launches.count } do
      Autopilot::Orchestrator.tick_project(@project)
    end
  end

  test "launching an item flips it to in_progress immediately so the next tick can't double-launch" do
    item = @project.tasks.create!(title: "Next", item_type: "task", board_state: "pending")
    Autopilot::Orchestrator.tick_project(@project)
    assert_equal "in_progress", item.reload.board_state,
                 "the item is in_progress the instant its session is queued"
    assert @project.board_busy?, "the project is now busy"

    # A second tick (e.g. the next ~60s heartbeat, before the agent has started)
    # must NOT launch a second session for the same project.
    assert_no_difference -> { @project.session_launches.where.not(pipeline_step: nil).count } do
      Autopilot::Orchestrator.tick_project(@project)
    end
  end
end
