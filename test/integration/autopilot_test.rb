require "test_helper"

# The autopilot orchestrator + agent-facing API contract: stepping the pipeline,
# the one-at-a-time / cap / kill-switch guardrails, the failed-item park, and the
# finish + board-field update endpoints the agents call.
class AutopilotTest < ActionDispatch::IntegrationTest
  setup do
    # Pin to 02:00 UTC so the daily review (gated to >= REVIEW_HOUR) does not
    # preempt the pipeline tests. Rails reverts the clock at teardown.
    travel_to Time.utc(2026, 6, 22, 2, 0, 0)
    @project = Project.create!(name: "AP", slug: "ap-#{SecureRandom.hex(3)}", repo_path: "/tmp/ap",
                               default_base_url: "http://example.test", autopilot_enabled: true)
    @item = @project.tasks.create!(title: "Pending item", item_type: "feature", board_state: "pending")
  end

  test "tick launches planning for the top pending item and counts the run" do
    assert_difference -> { SessionLaunch.where(pipeline_step: "planning").count }, 1 do
      Autopilot::Orchestrator.tick!
    end
    assert_equal 1, @project.reload.autopilot_runs_count
  end

  test "one item at a time — a second tick does not launch while in flight" do
    Autopilot::Orchestrator.tick!
    assert_no_difference -> { SessionLaunch.count } do
      Autopilot::Orchestrator.tick!
    end
  end

  test "global kill switch prevents launches" do
    Setting.autopilot_stopped = true
    assert_no_difference("SessionLaunch.count") { Autopilot::Orchestrator.tick! }
  end

  test "daily cap is respected" do
    @project.update!(autopilot_daily_cap: 0)
    assert_no_difference("SessionLaunch.count") { Autopilot::Orchestrator.tick! }
  end

  test "run_once advances even when autopilot is disabled" do
    @project.update!(autopilot_enabled: false)
    assert_difference -> { SessionLaunch.where(pipeline_step: "planning").count }, 1 do
      Autopilot::Orchestrator.run_once(@project)
    end
  end

  test "a planned engineering item launches the engineering agent" do
    @item.update!(board_state: "planned", agent_role: "engineering")
    Autopilot::Orchestrator.tick!
    assert SessionLaunch.where(pipeline_step: "engineering", task_id: @item.id).exists?
  end

  test "an exhausted failed item is parked to waiting" do
    @item.update!(board_state: "failed", autopilot_attempts: Task::MAX_AUTOPILOT_ATTEMPTS)
    Autopilot::Orchestrator.tick!
    assert_equal "waiting", @item.reload.board_state
  end

  test "daily review launches in the morning when none has run today" do
    travel_to Time.utc(2026, 6, 22, 14, 0, 0)
    assert_difference -> { SessionLaunch.where(pipeline_step: "review").count }, 1 do
      Autopilot::Orchestrator.tick!
    end
  end

  test "global concurrency cap blocks new launches when the fleet is full" do
    # Saturate the global slots with GLOBAL_MAX_CONCURRENT in-flight board launches
    # on other projects, then confirm our active project gets nothing this tick.
    Autopilot::Orchestrator::GLOBAL_MAX_CONCURRENT.times do |i|
      pr = Project.create!(name: "busy#{i}", slug: "busy-#{SecureRandom.hex(3)}", repo_path: "/tmp/busy#{i}")
      SessionLaunch.queue!(project: pr, prompt: "x", pipeline_step: "planning",
                           task: pr.tasks.create!(title: "t", board_state: "planned", agent_role: "engineering"))
    end
    assert_no_difference("SessionLaunch.count") { Autopilot::Orchestrator.tick! }
  end

  test "review is skipped when the review agent is disabled, but the pipeline still runs" do
    travel_to Time.utc(2026, 6, 22, 14, 0, 0)
    @project.update!(autopilot_review_enabled: false)
    Autopilot::Orchestrator.tick!
    assert_equal 0, SessionLaunch.where(pipeline_step: "review").count, "review must not run when disabled"
    assert SessionLaunch.where(pipeline_step: "planning").exists?, "pipeline should still advance the pending item"
  end

  test "engineering launch uses the project base branch" do
    @project.update!(base_branch: "2.3")
    @item.update!(board_state: "planned", agent_role: "engineering")
    Autopilot::Orchestrator.tick!
    launch = SessionLaunch.where(pipeline_step: "engineering").last
    assert_includes launch.prompt, "2.3"
  end

  test "api autopilot tick endpoint runs the orchestrator" do
    post "/api/v1/autopilot/tick"
    assert_response :success
    assert response.parsed_body["ok"]
  end

  test "api finish triggers a test run when the item has a plan" do
    plan = @project.test_plans.create!(title: "Plan")
    plan.test_cases.create!(title: "case 1", tier: "acceptance")
    TestPlanTask.create!(test_plan: plan, task: @item)
    assert_difference -> { TestRun.count }, 1 do
      post "/api/v1/projects/#{@project.slug}/tasks/#{@item.id}/finish", params: {}, as: :json
    end
    assert_response :success
    assert response.parsed_body["ok"]
  end

  test "api task update permits board + PR fields and stamps timestamps" do
    patch "/api/v1/projects/#{@project.slug}/tasks/#{@item.id}",
          params: { task: { board_state: "in_review", pr_url: "http://x/pr/3", pr_number: 3,
                            pr_state: "open", branch_name: "board/x", plan: "do it" } }, as: :json
    assert_response :success
    @item.reload
    assert_equal "in_review", @item.board_state
    assert_equal 3, @item.pr_number
    assert_not_nil @item.finished_at
    assert_not_nil @item.plan_updated_at
  end
end
