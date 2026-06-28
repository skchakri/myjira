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
end
