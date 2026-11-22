require "test_helper"

class WorkQueuePageTest < ActionDispatch::IntegrationTest
  setup do
    @dir = Dir.mktmpdir("wq")
    File.write(File.join(@dir, "home-me-app.json"), {
      items: [{ n: 7, title: "Build thing", status: "blocked", questions: [{ q: "Color?", options: %w[red blue] }], log: [] },
              { n: 8, title: "Next", status: "queued", questions: [], log: [] }]
    }.to_json)
    @old = ENV["WORK_QUEUE_DIR"]
    ENV["WORK_QUEUE_DIR"] = @dir
  end

  teardown do
    ENV["WORK_QUEUE_DIR"] = @old
    FileUtils.rm_rf(@dir)
  end

  test "renders grouped items, badges and option chips" do
    get work_queue_path(item: "home-me-app:7")
    assert_response :ok
    assert_select "#wq_project_home-me-app .wq-card", 2
    assert_select ".wq-s-waiting"
    assert_select ".wq-pop .wq-chip", text: /red/
    assert_select "form[action=?]", work_queue_item_run_path("home-me-app:8")
  end

  test "answer without a live session is written by the server" do
    post work_queue_item_answer_path("home-me-app:7"), params: { index: 0, text: "blue" }, as: :turbo_stream
    assert_response :ok
    assert_equal "blue", WorkQueue::Store.new.find("home-me-app:7").questions.first.a
  end

  test "group needs two items from one project" do
    post work_queue_group_path, params: { keys: ["home-me-app:7"] }, as: :turbo_stream
    assert_includes response.body, "Select at least two"
  end

  test "unknown item is 404" do
    post work_queue_item_run_path("home-me-app:99"), as: :turbo_stream
    assert_response :not_found
  end
end

class WorkQueueServerModeTest < ActionDispatch::IntegrationTest
  setup do
    @dir = Dir.mktmpdir("wq")
    @old = ENV["WORK_QUEUE_DIR"]
    ENV["WORK_QUEUE_DIR"] = @dir
    WorkQueue::QueueWriter.new(dir: @dir).add("home-me-app", title: "Existing")
    redis = WorkQueue::RunState.redis
    redis.scan_each(match: "#{WorkQueue::RunState::PREFIX}:*") { |k| redis.del(k) }
  end

  teardown do
    ENV["WORK_QUEUE_DIR"] = @old
    FileUtils.rm_rf(@dir)
  end

  test "composer adds an item and can queue it for the runner" do
    post work_queue_items_path, params: { slug: "home-me-app", text: "Add dark mode\nmore detail", start: "1" }, as: :turbo_stream
    assert_response :ok
    item = WorkQueue::Store.new.find("home-me-app:2")
    assert_equal "Add dark mode", item.title
    job = JSON.parse(WorkQueue::RunState.redis.lpop(WorkQueue::RunState::JOBS))
    assert_equal %w[start home-me-app:2], [job["action"], job["key"]]
  end

  test "answer without a session writes the queue directly" do
    WorkQueue::QueueWriter.new(dir: @dir).ask("home-me-app", 1, [{ q: "Color?", options: %w[red] }])
    post work_queue_item_answer_path("home-me-app:1"), params: { index: 0, text: "red" }, as: :turbo_stream
    assert_response :ok
    assert_equal "red", WorkQueue::Store.new.find("home-me-app:1").questions.first.a
  end

  test "pasted reference links two items" do
    WorkQueue::QueueWriter.new(dir: @dir).add("home-me-app", title: "Other")
    post work_queue_item_instruct_path("home-me-app:1"), params: { text: "[wq-ref home-me-app:2] #2 Other\nsync" }, as: :turbo_stream
    assert_includes WorkQueue::RunState.related("home-me-app:1"), "home-me-app:2"
    get work_queue_path(item: "home-me-app:1")
    assert_select ".wq-links a", text: /#2 Other/
    assert_select ".wq-log-h .wq-copy-item", 2
  end

  test "settings save a validated routing table" do
    patch work_queue_settings_path, params: { routing: { plan: { model: "claude-sonnet-5-5", effort: "max" }, implement: { model: "nope", effort: "low" } } }
    assert_redirected_to work_queue_settings_path
    table = WorkQueue::RunState.routing
    assert_equal "claude-sonnet-5-5", table["plan"]["model"]
    assert_equal "claude-sonnet-5-5", table["implement"]["model"]
  end
end
