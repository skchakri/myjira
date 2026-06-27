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

  # --- task result write-back -----------------------------------------------
  def task!
    @project.tasks.create!(title: "Run an agent on me")
  end

  def queue_for(task:, pipeline_step: nil, agent: nil)
    SessionLaunch.queue!(project: @project, prompt: "do x", task: task,
                         pipeline_step: pipeline_step, agent: agent)
  end

  test "terminal transition on a task-bound, non-pipeline launch posts exactly one comment" do
    task = task!
    launch = queue_for(task: task)
    assert_difference -> { task.comments.count }, 1 do
      launch.update!(status: "launched", launched_at: Time.current)
    end
    assert_match(/Agent run/, task.comments.last.body)
  end

  test "the comment outcome wording matches #outcome" do
    task = task!
    launch = queue_for(task: task)
    launch.update!(status: "failed")
    assert_includes task.comments.last.body, launch.outcome
    assert_equal "failed", launch.outcome
  end

  test "a pipeline launch posts no auto-comment" do
    task = task!
    launch = queue_for(task: task, pipeline_step: "engineering")
    assert_no_difference -> { task.comments.count } do
      launch.update!(status: "launched", launched_at: Time.current)
    end
  end

  test "a launch with no task posts no comment" do
    launch = @project.session_launches.create!(prompt: "do x")
    assert_nothing_raised { launch.update!(status: "launched", launched_at: Time.current) }
  end

  test "re-PATCHing the same terminal status does not duplicate the comment" do
    task = task!
    launch = queue_for(task: task)
    launch.update!(status: "failed")
    assert_no_difference -> { task.comments.count } do
      launch.update!(status: "failed", launched_at: Time.current)
      launch.touch
    end
  end

  test "a terminal-to-terminal transition does not post a second comment" do
    task = task!
    launch = queue_for(task: task)
    launch.update!(status: "launched", launched_at: Time.current)
    assert_no_difference -> { task.comments.count } do
      launch.update!(status: "failed")
    end
  end
end
