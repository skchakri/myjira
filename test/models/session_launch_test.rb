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

  # --- project memory injection ---------------------------------------------
  test "queue! with empty memory leaves the prompt unchanged" do
    sl = SessionLaunch.queue!(project: @project, prompt: "build the thing")
    assert_equal "build the thing", sl.prompt
  end

  test "queue! prepends the project memory block while keeping the title from the raw prompt" do
    @project.update!(memory_preamble: "UUID PKs everywhere.")
    KnowledgeFact.record!(project: @project, body: "auth lives in app/services/auth")

    sl = SessionLaunch.queue!(project: @project, prompt: "build the thing")
    assert_includes sl.prompt, "UUID PKs everywhere."
    assert_includes sl.prompt, "auth lives in app/services/auth"
    assert sl.prompt.end_with?("build the thing"), "raw prompt must be appended after the memory block"
    assert_includes sl.prompt, "\n\n---\n\n"
    # The bound conversation's title derives from the raw prompt, not the memory.
    assert_equal "build the thing", sl.conversation.title
  end
end
