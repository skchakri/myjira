require "test_helper"

class BoardSessionSyncTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "SS", slug: "ss-#{SecureRandom.hex(3)}", repo_path: "/tmp/ss")
  end

  def in_progress_with_launch(target: "myjira:ss-abc", launched_at: 10.minutes.ago)
    task = @project.tasks.create!(title: "WIP", item_type: "task", board_state: "in_progress")
    @project.session_launches.create!(prompt: "/board-engineer", status: "launched",
                                      repo_path: "/tmp/ss", session_id: SecureRandom.uuid,
                                      pipeline_step: "engineering",
                                      tmux_target: target, launched_at: launched_at, task: task)
    task
  end

  test "work lists in_progress items with a launched tmux target past the spawn grace" do
    task = in_progress_with_launch
    rows = Board::SessionSync.work
    assert_equal [task.id], rows.map { |r| r[:task_id] }
    assert_equal "myjira:ss-abc", rows.first[:tmux_target]
  end

  test "work skips a launch still inside the spawn grace" do
    in_progress_with_launch(launched_at: 5.seconds.ago)
    assert_empty Board::SessionSync.work
  end

  test "apply! with alive:false demotes the in_progress item back to pending" do
    task = in_progress_with_launch
    assert_equal "requeued", Board::SessionSync.apply!(task, alive: false)
    task.reload
    assert_equal "pending", task.board_state
    assert_equal 1, task.autopilot_attempts
    assert_match(/re-queued/i, task.agent_notes)
  end

  test "apply! with alive:true is a no-op" do
    task = in_progress_with_launch
    assert_equal "alive", Board::SessionSync.apply!(task, alive: true)
    assert_equal "in_progress", task.reload.board_state
  end

  test "apply! never demotes an item that already left in_progress" do
    task = in_progress_with_launch
    task.update!(board_state: "in_review")
    assert_equal "not_in_progress", Board::SessionSync.apply!(task, alive: false)
    assert_equal "in_review", task.reload.board_state
  end
end
