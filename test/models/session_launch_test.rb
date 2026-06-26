require "test_helper"

# The derived spawn-outcome read-model the launcher metrics roll up. There's no
# stored column — #outcome maps (status, launched_at) onto OUTCOMES, with
# "launched" ageing from running → succeeded once it leaves the active window.
class SessionLaunchTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "SL", slug: "sl-#{SecureRandom.hex(3)}", repo_path: "/tmp/sl")
  end

  def launch(status:, launched_at: nil)
    @project.session_launches.create!(prompt: "do x", status: status, launched_at: launched_at)
  end

  test "pending and launching are running" do
    assert_equal "running", launch(status: "pending").outcome
    assert_equal "running", launch(status: "launching").outcome
  end

  test "failed is failed and canceled maps to cancelled" do
    assert_equal "failed", launch(status: "failed").outcome
    assert_equal "cancelled", launch(status: "canceled").outcome
  end

  test "launched inside the active window is still running" do
    l = launch(status: "launched", launched_at: 2.minutes.ago)
    assert_equal "running", l.outcome
  end

  test "launched past the active window is succeeded" do
    l = launch(status: "launched", launched_at: (SessionLaunch::ACTIVE_LAUNCHED_WINDOW + 5.minutes).ago)
    assert_equal "succeeded", l.outcome
  end

  test "launched with no launched_at is treated as succeeded (not in flight)" do
    assert_equal "succeeded", launch(status: "launched").outcome
  end

  test "every derived outcome is one of OUTCOMES" do
    SessionLaunch::STATUSES.each do |status|
      assert_includes SessionLaunch::OUTCOMES, launch(status: status).outcome
    end
  end

  test "the active scope and #outcome agree on the launched window boundary" do
    fresh = launch(status: "launched", launched_at: 1.minute.ago)
    stale = launch(status: "launched", launched_at: 1.hour.ago)
    assert_includes @project.session_launches.active, fresh
    refute_includes @project.session_launches.active, stale
    assert_equal "running", fresh.outcome
    assert_equal "succeeded", stale.outcome
  end

  # --- Worklog timeline ------------------------------------------------------
  test "queue! writes a launch.queued worklog node" do
    sl = SessionLaunch.queue!(project: @project, prompt: "do x")
    node = sl.worklog_events.chronological.first
    assert_equal "launch.queued", node.name
    assert_equal "running", node.status
  end

  test "a status flip writes exactly one node mapping the new status" do
    sl = launch(status: "pending")
    assert_difference -> { sl.worklog_events.count }, 1 do
      sl.update!(status: "launched", launched_at: Time.current, tmux_target: "myjira:3")
    end
    node = sl.worklog_events.chronological.last
    assert_equal "launch.spawned", node.name
    assert_equal "running", node.status
    assert_equal "myjira:3", node.payload["tmux_target"]
  end

  test "re-PATCHing the same status writes no new node" do
    sl = launch(status: "failed")
    sl.worklog_events.delete_all
    assert_no_difference -> { sl.worklog_events.count } do
      sl.update!(status: "failed", error: "still broken")
    end
  end
end
