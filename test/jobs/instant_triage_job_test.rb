require "test_helper"

class InstantTriageJobTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Triage", slug: "triage-#{SecureRandom.hex(3)}",
                               repo_path: "/tmp/triage-#{SecureRandom.hex(3)}")
    @task = @project.tasks.create!(title: "Add OAuth login", board_state: "pending",
                                   description: "Support Google sign-in on the login page.")
  end

  VALID_SUGGESTION = {
    "agent_role" => "engineering",
    "priority"   => "normal",
    "labels"     => ["auth", "oauth"],
    "plan_sketch" => "Implement Google OAuth via omniauth gem."
  }.freeze

  def valid_api_response
    VALID_SUGGESTION.to_json
  end

  def run_job(task = @task)
    job = InstantTriageJob.new
    job.stub(:call_api, VALID_SUGGESTION) { job.perform(task.id) }
  end

  test "stores triage_suggestion on task when auto_triage disabled" do
    run_job
    @task.reload
    assert_equal "engineering", @task.triage_suggestion["agent_role"]
    assert_equal "normal",      @task.triage_suggestion["priority"]
    assert_includes @task.triage_suggestion["labels"], "auth"
  end

  test "returns early when task not found" do
    assert_nothing_raised { InstantTriageJob.new.perform(SecureRandom.uuid) }
  end

  test "returns early when triage_suggestion already set" do
    @task.update!(triage_suggestion: { "agent_role" => "answer_only" })
    call_count = 0
    job = InstantTriageJob.new
    job.stub(:call_api, ->(*) { call_count += 1; VALID_SUGGESTION }) do
      job.perform(@task.id)
    end
    assert_equal 0, call_count, "should not call API when suggestion already set"
  end

  test "returns early when board_state is not pending" do
    @task.update_column(:board_state, "planned") # rubocop:disable Rails/SkipsModelValidations
    call_count = 0
    job = InstantTriageJob.new
    job.stub(:call_api, ->(*) { call_count += 1; VALID_SUGGESTION }) do
      job.perform(@task.id)
    end
    assert_equal 0, call_count, "should not call API when board_state != pending"
  end

  test "auto-applies fields when project has auto_triage_enabled" do
    @project.update!(auto_triage_enabled: true)
    run_job
    @task.reload
    assert_nil @task.triage_suggestion, "suggestion should be cleared after auto-apply"
    assert_equal "engineering", @task.agent_role
    assert_equal "normal",      @task.priority
    assert_includes @task.labels, "auth"
  end

  test "does not overwrite manually set agent_role when auto-applying" do
    @project.update!(auto_triage_enabled: true)
    @task.update!(agent_role: "debugger")
    run_job
    @task.reload
    assert_equal "debugger", @task.agent_role, "manual role should not be overwritten"
  end

  test "handles nil return from call_api gracefully" do
    job = InstantTriageJob.new
    job.stub(:call_api, nil) { job.perform(@task.id) }
    @task.reload
    assert_nil @task.triage_suggestion
  end

  test "runs the consolidator for a pending item after triage" do
    called = nil
    job = InstantTriageJob.new
    Board::Consolidator.stub(:run!, ->(t) { called = t.id }) do
      job.stub(:call_api, VALID_SUGGESTION) { job.perform(@task.id) }
    end
    assert_equal @task.id, called
  end
end
