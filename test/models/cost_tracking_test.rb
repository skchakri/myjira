require "test_helper"

# Layer A/B model-level wiring: token rollup, cap inheritance, daily spend, badge.
class CostTrackingTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "CT", slug: "ct-#{SecureRandom.hex(3)}", repo_path: "/tmp/ct")
  end

  def convo
    @convo ||= @project.conversations.create!(session_id: SecureRandom.uuid, model: "opus")
  end

  def assistant_message(usage:)
    convo.conversation_messages.create!(
      ext_id: SecureRandom.uuid, role: "assistant", kind: "message", body: "hi",
      position: (convo.conversation_messages.maximum(:position) || -1) + 1,
      occurred_at: Time.current, payload: usage ? { "usage" => usage } : {}
    )
  end

  # --- Conversation#token_totals ---

  test "token_totals sums usage across assistant messages" do
    assistant_message(usage: { "input_tokens" => 100, "output_tokens" => 20,
                               "cache_read_input_tokens" => 5, "cache_creation_input_tokens" => 3 })
    assistant_message(usage: { "input_tokens" => 50, "output_tokens" => 10 })
    totals = convo.token_totals
    assert_equal({ input: 150, output: 30, cache_read: 5, cache_creation: 3 }, totals)
  end

  test "token_totals is nil when no message carries usage" do
    assistant_message(usage: nil)
    assert_nil convo.token_totals
  end

  # --- SessionLaunch.queue! cap + turns inheritance ---

  test "a board launch inherits the project per-run cap" do
    @project.update!(autopilot_budget_cap_cents: 250)
    task = @project.tasks.create!(title: "t", item_type: "task")
    launch = SessionLaunch.queue!(project: @project, prompt: "/board-engineer x",
                                  task: task, pipeline_step: "engineering", source: "board")
    assert_equal 250, launch.budget_cap_cents
  end

  test "an ad-hoc (non-pipeline) launch stays uncapped" do
    @project.update!(autopilot_budget_cap_cents: 250)
    launch = SessionLaunch.queue!(project: @project, prompt: "hello")
    assert_nil launch.budget_cap_cents
  end

  test "an explicit cap overrides the project default" do
    @project.update!(autopilot_budget_cap_cents: 250)
    task = @project.tasks.create!(title: "t", item_type: "task")
    launch = SessionLaunch.queue!(project: @project, prompt: "/board-engineer x", task: task,
                                  pipeline_step: "engineering", source: "board", budget_cap_cents: 999)
    assert_equal 999, launch.budget_cap_cents
  end

  test "max_turns_flag is nil when unset and the value when positive" do
    launch = @project.session_launches.create!(prompt: "x", session_id: SecureRandom.uuid, repo_path: "/tmp/ct")
    assert_nil launch.max_turns_flag
    launch.update!(max_turns: 40)
    assert_equal 40, launch.max_turns_flag
  end

  # --- Project#spend_today_cents + dollars accessor ---

  test "spend_today_cents sums today's launches and ignores nil + yesterday" do
    @project.session_launches.create!(prompt: "a", session_id: SecureRandom.uuid, repo_path: "/tmp/ct", estimated_cost_cents: 30)
    @project.session_launches.create!(prompt: "b", session_id: SecureRandom.uuid, repo_path: "/tmp/ct", estimated_cost_cents: nil)
    yday = @project.session_launches.create!(prompt: "c", session_id: SecureRandom.uuid, repo_path: "/tmp/ct", estimated_cost_cents: 500)
    yday.update_column(:created_at, 1.day.ago)
    assert_equal 30, @project.spend_today_cents
  end

  test "the dollars accessor round-trips to cents and blanks to nil" do
    @project.autopilot_budget_cap_dollars = "1.50"
    assert_equal 150, @project.autopilot_budget_cap_cents
    assert_in_delta 1.5, @project.autopilot_budget_cap_dollars, 0.001
    @project.autopilot_budget_cap_dollars = ""
    assert_nil @project.autopilot_budget_cap_cents
  end

  # --- Task#over_budget? ---

  test "over_budget? is true once any launch on the item is flagged" do
    task = @project.tasks.create!(title: "t", item_type: "task")
    @project.session_launches.create!(prompt: "x", session_id: SecureRandom.uuid, repo_path: "/tmp/ct", task: task)
    refute task.over_budget?
    @project.session_launches.create!(prompt: "y", session_id: SecureRandom.uuid, repo_path: "/tmp/ct", task: task, over_budget: true)
    assert task.over_budget?
  end

  # --- PlaybookRun delegation ---

  test "playbook run delegates cost/usage to its launch" do
    playbook = @project.playbooks.create!(name: "p", body: "b")
    launch = @project.session_launches.create!(prompt: "x", session_id: SecureRandom.uuid,
                                               repo_path: "/tmp/ct", token_input: 10, estimated_cost_cents: 42)
    run = playbook.playbook_runs.create!(result: "pending", session_launch: launch)
    assert_equal 10, run.token_input
    assert_equal 42, run.estimated_cost_cents
  end
end
