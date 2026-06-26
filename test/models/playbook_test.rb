require "test_helper"

# A Playbook is a saved run recipe. The contract: run_prompt weaves the body with
# success-criteria/guardrails blocks (and an agent's framing); trigger! queues a
# SessionLaunch + a pending PlaybookRun in the project's repo; metrics_for rolls
# up pass/fail history without N+1 and zero-fills never-run playbooks.
class PlaybookTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "PB", slug: "pb-#{SecureRandom.hex(3)}", repo_path: "/tmp/pb")
  end

  def playbook(**attrs)
    @project.playbooks.create!({ name: "Nightly sweep", body: "Run the flaky-test sweep." }.merge(attrs))
  end

  test "requires a name and a body" do
    assert_not Playbook.new(project: @project).valid?
    pb = Playbook.new(project: @project, name: "x")
    assert_not pb.valid?
    assert_includes pb.errors[:body], "can't be blank"
  end

  test "rejects a model/permission_mode outside the SessionLaunch allow-lists" do
    pb = @project.playbooks.new(name: "x", body: "y", model: "gpt-9")
    assert_not pb.valid?
    pb.model = "opus"
    pb.permission_mode = "yolo"
    assert_not pb.valid?
    pb.permission_mode = "acceptEdits"
    assert pb.valid?
  end

  test "run_prompt weaves success criteria and guardrails into the body" do
    pb = playbook(body: "Do the thing.", success_criteria: "Tests green.", guardrails: "Don't push.")
    prompt = pb.run_prompt
    assert_includes prompt, "Do the thing."
    assert_includes prompt, "Success criteria:\nTests green."
    assert_includes prompt, "Guardrails:\nDon't push."
  end

  test "run_prompt omits empty blocks and frames with the agent when present" do
    agent = Agent.create!(name: "tester", kind: "agent", scope: "project", project: @project)
    pb = playbook(body: "Body only.", agent: agent)
    prompt = pb.run_prompt
    assert_includes prompt, agent.launch_prompt
    assert_includes prompt, "Body only."
    assert_not_includes prompt, "Success criteria:"
    assert_not_includes prompt, "Guardrails:"
  end

  test "trigger! queues a SessionLaunch and records a pending PlaybookRun" do
    pb = playbook
    assert_difference -> { SessionLaunch.count } => 1, -> { PlaybookRun.count } => 1 do
      run = pb.trigger!
      assert_equal "pending", run.result
      assert_equal pb, run.playbook
      assert_equal "playbook", run.session_launch.conversation.source
    end
  end

  test "trigger! returns nil when the project has no repo path" do
    repoless = Project.create!(name: "NR", slug: "nr-#{SecureRandom.hex(3)}")
    pb = repoless.playbooks.create!(name: "x", body: "y")
    assert_no_difference -> { SessionLaunch.count } do
      assert_nil pb.trigger!
    end
  end

  test "metrics_for zero-fills a never-run playbook" do
    pb = playbook
    m = Playbook.metrics_for([pb])[pb.id]
    assert_equal 0, m[:runs]
    assert_equal 0, m[:pass_rate]
    assert_nil m[:last_run_at]
    assert_equal Array.new(7, 0), m[:sparkline]
  end

  test "metrics_for counts results and computes pass_rate over decided runs" do
    pb = playbook
    pb.playbook_runs.create!(result: "passed", evaluated_at: 1.hour.ago)
    pb.playbook_runs.create!(result: "passed", evaluated_at: 1.hour.ago)
    pb.playbook_runs.create!(result: "failed", evaluated_at: 1.hour.ago)
    pb.playbook_runs.create!(result: "pending")
    m = Playbook.metrics_for([pb])[pb.id]
    assert_equal 4, m[:runs]
    assert_equal 2, m[:passed]
    assert_equal 1, m[:failed]
    assert_equal 1, m[:pending]
    assert_equal 67, m[:pass_rate], "pass_rate is over passed+failed, ignoring pending"
  end

  test "metrics_for is a single query regardless of playbook count" do
    a = playbook
    b = playbook(name: "two")
    a.playbook_runs.create!(result: "passed")
    b.playbook_runs.create!(result: "failed")
    count = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      count += 1 if payload[:name] != "SCHEMA" && payload[:sql].include?('FROM "playbook_runs"')
    end
    Playbook.metrics_for([a, b])
    ActiveSupport::Notifications.unsubscribe(sub)
    assert_equal 1, count, "metrics must not N+1 across playbooks"
  end
end
