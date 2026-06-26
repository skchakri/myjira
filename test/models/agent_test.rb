require "test_helper"

# Agent.metrics_for is the bulk launcher read-model: one query over
# session_launches, grouped in Ruby into per-agent run/outcome counts plus a
# trailing-7-day sparkline. The contract is "never N+1, zeroed entry for every
# agent asked about".
class AgentTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "AG", slug: "ag-#{SecureRandom.hex(3)}", repo_path: "/tmp/ag")
    @agent   = Agent.create!(name: "tester", kind: "agent", scope: "project", project: @project)
  end

  def launch(agent:, status: "launched", launched_at: 1.hour.ago)
    @project.session_launches.create!(prompt: "x", agent: agent, status: status, launched_at: launched_at)
  end

  # Count SELECTs that hit session_launches during the block — the N+1 guard.
  def session_launch_queries
    count = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      count += 1 if payload[:name] != "SCHEMA" && payload[:sql].include?('FROM "session_launches"')
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  test "an agent with no launches gets a fully zeroed entry" do
    m = Agent.metrics_for([@agent])[@agent.id]
    assert_equal 0, m[:runs]
    assert_equal 0, m[:succeeded]
    assert_nil m[:last_run_at]
    assert_equal Array.new(7, 0), m[:sparkline]
  end

  test "metrics_for counts runs and each derived outcome" do
    launch(agent: @agent, status: "launched", launched_at: 2.hours.ago)  # succeeded
    launch(agent: @agent, status: "failed")                              # failed
    launch(agent: @agent, status: "canceled")                            # cancelled
    launch(agent: @agent, status: "launched", launched_at: 1.minute.ago) # running (in window)
    m = Agent.metrics_for([@agent])[@agent.id]
    assert_equal 4, m[:runs]
    assert_equal 1, m[:succeeded]
    assert_equal 1, m[:failed]
    assert_equal 1, m[:cancelled]
    assert_equal 1, m[:running]
  end

  test "metrics_for tracks the most recent run time" do
    launch(agent: @agent, launched_at: 3.days.ago)
    recent = launch(agent: @agent, launched_at: 1.hour.ago)
    m = Agent.metrics_for([@agent])[@agent.id]
    assert_in_delta recent.launched_at.to_i, m[:last_run_at].to_i, 2
  end

  test "sparkline is length 7 and buckets launches by local day" do
    launch(agent: @agent, launched_at: Time.zone.now.change(hour: 12))  # today  → index 6
    launch(agent: @agent, launched_at: 2.days.ago.change(hour: 12))     # -2 days → index 4
    launch(agent: @agent, launched_at: 2.days.ago.change(hour: 9))      # -2 days → index 4
    m = Agent.metrics_for([@agent])[@agent.id]
    assert_equal 7, m[:sparkline].length
    assert_equal 1, m[:sparkline][6], "today is the last bucket"
    assert_equal 2, m[:sparkline][4], "two same-day launches share a bucket"
  end

  test "launches older than 7 days count in totals but fall off the sparkline" do
    launch(agent: @agent, launched_at: 30.days.ago)
    m = Agent.metrics_for([@agent])[@agent.id]
    assert_equal 1, m[:runs]
    assert_equal Array.new(7, 0), m[:sparkline]
  end

  test "metrics_for ignores plain launches with no agent" do
    launch(agent: nil)
    assert_equal 0, Agent.metrics_for([@agent])[@agent.id][:runs]
  end

  test "metrics_for is a single query regardless of agent count" do
    other = Agent.create!(name: "two", kind: "skill", scope: "project", project: @project)
    launch(agent: @agent)
    launch(agent: other)
    queries = session_launch_queries { Agent.metrics_for([@agent, other]) }
    assert_equal 1, queries, "metrics must not N+1 across agents"
  end

  test "metrics_for makes no query when given no agents" do
    queries = session_launch_queries { assert_empty Agent.metrics_for([]) }
    assert_equal 0, queries
  end

  test "#metrics returns this agent's slice, reusing a preloaded bulk hash" do
    launch(agent: @agent)
    bulk = Agent.metrics_for([@agent])
    queries = session_launch_queries { assert_equal 1, @agent.metrics(bulk)[:runs] }
    assert_equal 0, queries, "passing the bulk hash avoids a second query"
  end
end
