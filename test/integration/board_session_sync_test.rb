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

  def in_progress_with_failed_launch(error: "tmux: create window failed: index 0 in use", created_at: 10.minutes.ago)
    task = @project.tasks.create!(title: "WIP", item_type: "task", board_state: "in_progress")
    @project.session_launches.create!(prompt: "/board-engineer", status: "failed",
                                      repo_path: "/tmp/ss", session_id: SecureRandom.uuid,
                                      pipeline_step: "engineering", error: error,
                                      tmux_target: nil, created_at: created_at, task: task)
    task
  end

  test "reap_failed! requeues an in_progress item whose latest launch failed to spawn" do
    task = in_progress_with_failed_launch
    assert_equal [task.id], Board::SessionSync.reap_failed!
    task.reload
    assert_equal "pending", task.board_state
    assert_equal 1, task.autopilot_attempts
    assert_match(/failed to spawn/i, task.agent_notes)
  end

  test "reap_failed! leaves a fresh failed launch inside the spawn grace alone" do
    in_progress_with_failed_launch(created_at: 5.seconds.ago)
    assert_empty Board::SessionSync.reap_failed!
  end

  test "reap_failed! ignores items whose latest launch is healthy" do
    in_progress_with_launch
    assert_empty Board::SessionSync.reap_failed!
  end

  test "GET session_sync returns the daemon check-list" do
    task = in_progress_with_launch
    get "/api/v1/board/session_sync"
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [task.id], body["to_check"].map { |h| h["task_id"] }
  end

  test "POST session_sync applies liveness outcomes" do
    task = in_progress_with_launch
    post "/api/v1/board/session_sync",
         params: { results: [{ task_id: task.id, alive: false }] }, as: :json
    assert_response :success
    assert_equal "pending", task.reload.board_state
  end
end
