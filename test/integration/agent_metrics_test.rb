require "test_helper"

# The launcher strip now annotates each agent pill with its run history. Guards
# the full render path (bulk metrics query → strip → pill/panel) and that a strip
# full of agents stays a single agent-scoped session_launches query (no N+1).
class AgentMetricsTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Strip", slug: "strip-#{SecureRandom.hex(3)}", repo_path: "/tmp/strip")
    @agent   = Agent.create!(name: "metrics-bot", kind: "agent", scope: "project", project: @project)
  end

  test "conversations index renders a run-count badge for a launched agent" do
    @project.session_launches.create!(prompt: "go", agent: @agent, status: "launched",
                                      launched_at: 2.hours.ago)
    get project_conversations_path(@project)
    assert_response :success
    assert_select "summary span[title*=?]", "ran 1×"
  end

  test "an agent that never ran shows the pill but no run badge" do
    get project_conversations_path(@project)
    assert_response :success
    assert_select "summary", text: /metrics-bot/
    assert_select 'summary span[title^="ran "]', false, "no run-count badge before first launch"
    assert_match "not run yet", response.body
  end

  test "the strip issues one agent-scoped session_launches query for many agents" do
    others = Array.new(3) { |i| Agent.create!(name: "bot-#{i}", kind: "agent", scope: "project", project: @project) }
    ([@agent] + others).each do |a|
      @project.session_launches.create!(prompt: "x", agent: a, status: "launched", launched_at: 1.hour.ago)
    end
    count = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      if payload[:name] != "SCHEMA" && payload[:sql].include?('FROM "session_launches"') &&
         payload[:sql].include?("agent_id")
        count += 1
      end
    end
    get project_conversations_path(@project)
    ActiveSupport::Notifications.unsubscribe(sub)
    assert_response :success
    assert_equal 1, count, "metrics_for must be the only agent_id-scoped session_launches query"
  end
end
