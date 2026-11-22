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
    assert_select ".wq-chip", text: /red/
    assert_select "form[action=?]", work_queue_item_run_path("home-me-app:8")
  end

  test "answer without a live session offers a copy command" do
    post work_queue_item_answer_path("home-me-app:7"), params: { index: 0, text: "blue" }, as: :turbo_stream
    assert_response :ok
    assert_includes response.body, "/item7 blue"
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
