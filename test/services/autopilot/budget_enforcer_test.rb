require "test_helper"

class Autopilot::BudgetEnforcerTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "BE", slug: "be-#{SecureRandom.hex(3)}", repo_path: "/tmp/be")
    @task = @project.tasks.create!(title: "Runaway", item_type: "task", board_state: "in_progress")
  end

  # An in-flight (active-scope) board launch with the given cost + cap, bound to @task.
  def launch(cost:, cap:, **extra)
    @project.session_launches.create!(
      prompt: "/board-engineer", status: "launched", launched_at: 1.minute.ago,
      session_id: SecureRandom.uuid, repo_path: "/tmp/be", pipeline_step: "engineering",
      task: @task, estimated_cost_cents: cost, budget_cap_cents: cap, **extra
    )
  end

  test "a launch under 80% of its cap is untouched" do
    l = launch(cost: 70, cap: 100)
    Autopilot::BudgetEnforcer.sweep!
    l.reload
    refute l.over_budget?
    assert_nil l.budget_alerted_at
    assert_equal "launched", l.status
  end

  test "at >=80% it soft-alerts exactly once" do
    l = launch(cost: 85, cap: 100)
    assert_difference -> { @task.comments.count }, 1 do
      Autopilot::BudgetEnforcer.sweep!
    end
    l.reload
    assert_not_nil l.budget_alerted_at
    refute l.over_budget?, "80% is a warning, not a kill"
    assert_equal "launched", l.status
    assert_match(/80%/, @task.comments.last.body)

    # Re-sweeping does not spam a second comment (idempotent on budget_alerted_at).
    assert_no_difference -> { @task.comments.count } do
      Autopilot::BudgetEnforcer.sweep!
    end
  end

  test "at >=100% it kills: over_budget, status canceling, item failed" do
    l = launch(cost: 120, cap: 100)
    Autopilot::BudgetEnforcer.sweep!
    l.reload
    assert l.over_budget?
    assert_not_nil l.over_budget_at
    assert_equal "canceling", l.status
    @task.reload
    assert_equal "failed", @task.board_state
    assert_equal 1, @task.autopilot_attempts
    assert_match(/budget cap/i, @task.agent_notes)
    assert @task.over_budget?
  end

  test "a kill is not repeated on the next sweep" do
    launch(cost: 120, cap: 100)
    Autopilot::BudgetEnforcer.sweep!
    assert_no_difference -> { @task.comments.count } do
      Autopilot::BudgetEnforcer.sweep!
    end
  end

  test "a launch with no cap is ignored" do
    l = launch(cost: 999, cap: nil)
    Autopilot::BudgetEnforcer.sweep!
    l.reload
    refute l.over_budget?
    assert_equal "launched", l.status
  end

  test "a launch with no captured cost yet is never killed on a phantom $0" do
    l = launch(cost: nil, cap: 100)
    Autopilot::BudgetEnforcer.sweep!
    l.reload
    refute l.over_budget?
  end

  test "enforcement still runs when autopilot is globally stopped" do
    Setting.autopilot_stopped = true
    launch(cost: 120, cap: 100)
    Autopilot::Orchestrator.tick!
    assert_equal "failed", @task.reload.board_state, "a runaway is killed even while stopped"
  ensure
    Setting.where(key: "autopilot_stopped").destroy_all
  end
end
