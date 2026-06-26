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
end
