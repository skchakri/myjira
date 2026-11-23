require "test_helper"

class WorkQueuePageTest < ActionDispatch::IntegrationTest
  setup do
    @dir = Dir.mktmpdir("wq")
    File.write(File.join(@dir, "home-me-app.json"), {
      items: [{ n: 7, title: "Build thing", status: "blocked", questions: [{ q: "Color?", options: %w[red blue] }, { q: "Size?", options: %w[S M] }], log: [] },
              { n: 8, title: "Next", status: "queued", questions: [], log: [] },
              { n: 9, title: "Follow on", status: "review", parent: 7, pr: "https://github.com/o/r/pull/12", questions: [], log: [] },
              { n: 10, title: "Sibling", status: "queued", parent: 7, awaitingApproval: true, questions: [], log: [] },
              { n: 11, title: "Shipped", status: "done", questions: [], log: [] },
              { n: 12, title: "Folded", status: "merged", mergedInto: 7, questions: [], log: [] }]
    }.to_json)
    @old = ENV["WORK_QUEUE_DIR"]
    ENV["WORK_QUEUE_DIR"] = @dir
  end

  teardown do
    ENV["WORK_QUEUE_DIR"] = @old
    FileUtils.rm_rf(@dir)
  end

  test "renders a project tree with follow-ups nested under their parent" do
    get work_queue_path(item: "home-me-app:7")
    assert_response :ok
    assert_select "#wq_project_home-me-app button.wq-proj[aria-expanded=true]", text: /app/
    assert_select "#wq_project_home-me-app .wq-pb-you", text: "3 need you"
    assert_select "#wq_project_home-me-app .wq-pb-n", text: "5"
    assert_select "#wq_project_home-me-app > .wq-tree > ul > li > .wq-card", 4 # 7, 8, 11, 12 are roots
    assert_select "li:has(> #wq_item_home-me-app_7) > ul > li > .wq-card", 2 do |kids|
      assert_includes kids.text, "follow-up"
    end
    assert_select "#wq_item_home-me-app_7 .wq-node-q", text: "2 ?"
    assert_select "#wq_item_home-me-app_7 .wq-card-link[aria-current=true]"
    assert_select "form[action=?]", work_queue_item_run_path("home-me-app:8")
  end

  test "filter chips and node tags map statuses to plain words" do
    get work_queue_path
    WorkQueue::Flow::FILTERS.each { |key, _| assert_select ".wq-tab[data-f=?]", key }
    assert_select ".wq-tab[data-f=all][aria-pressed=true]"
    tags = ->(n) { css_select("#wq_item_home-me-app_#{n}").first["data-tags"].split }
    assert_equal %w[all open you answer], tags.(7)
    assert_equal %w[all open wait], tags.(8)
    assert_includes tags.(9), "merge"
    assert_includes tags.(10), "approve"
    assert_equal %w[ok], tags.(11)
    assert_equal %w[closed], tags.(12)
    assert_select "#wq_item_home-me-app_7 .wq-node-s", text: "Needs your answer"
    assert_select "#wq_item_home-me-app_9 .wq-node-s", text: "Ready to merge"
    assert_select "#wq_item_home-me-app_10 .wq-node-s", text: "Needs your approval"
    assert_select "#wq_item_home-me-app_11 .wq-node-s", text: "Live"
  end

  test "detail shows breadcrumb, path, questions first and related tasks" do
    get work_queue_item_detail_path("home-me-app:9")
    assert_select ".wq-crumbs a", text: "Build thing"
    assert_select ".wq-pill-you", text: "Ready to merge"
    assert_select ".wq-step[aria-current=step]", text: "Review"
    assert_select ".wq-related .wq-rel-kind", text: "Came from"
    assert_select ".wq-related .wq-rel-kind", text: "Sibling"

    get work_queue_item_detail_path("home-me-app:7")
    assert_select ".wq-qbox h3", text: "2 questions for you"
    assert_select ".wq-qbox input[type=radio][name='answers[0]'][value=red]"
    assert_select ".wq-qbox .wq-chip-rec", text: /red \(suggested\)/
    assert_select ".wq-qbox textarea[name='custom[1]']"
    assert_select ".wq-qbox button[type=submit]", text: "Send answers"
    assert_select ".wq-related .wq-rel-kind", text: "Follow-up", count: 2
    header = css_select("#wq_log_header").first.to_html
    assert_operator header.index("wq-qbox"), :<, header.index("wq-now")
  end

  test "question box has stable per-item ids so drafts survive live re-renders" do
    2.times do
      get work_queue_item_detail_path("home-me-app:7")
      assert_select ".wq-qbox[data-work-queue-target=question][data-item-key='home-me-app:7']"
      assert_select ".wq-qbox[data-action*='work-queue#saveDraft'][data-action*='work-queue#clearDraft']"
      assert_select ".wq-qbox textarea#wq_custom_home-me-app-7_1[name='custom[1]']"
      assert_select ".wq-qbox input#wq_answer_home-me-app-7_0_0[name='answers[0]'][value=red]"
    end
  end

  test "send answers posts several answers at once; free text wins" do
    post work_queue_item_answer_path("home-me-app:7"),
         params: { answers: { "0" => "red", "1" => "S" }, custom: { "0" => "", "1" => "XL please" } }, as: :turbo_stream
    assert_response :ok
    assert_equal ["red", "XL please"], WorkQueue::Store.new.find("home-me-app:7").questions.map(&:a)
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

  test "run now approves a follow-up awaiting approval" do
    WorkQueue::QueueWriter.new(dir: @dir).add("home-me-app", title: "Follow-up", parent: 1)
    assert WorkQueue::Store.new.find("home-me-app:2").awaiting_approval

    post work_queue_item_run_path("home-me-app:2"), as: :turbo_stream
    assert_response :ok
    item = WorkQueue::Store.new.find("home-me-app:2")
    assert_not item.awaiting_approval
    assert_equal "queued", item.status
    assert(item.log.any? { |l| l["text"].to_s.include?("Approved via Run now") })
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
    get work_queue_item_detail_path("home-me-app:1")
    assert_select "turbo-frame#wq_detail .wq-related .wq-rel", text: /Other/
    assert_select ".wq-log-h .wq-copy-item", 2
  end

  test "settings save a validated routing table" do
    patch work_queue_settings_path, params: { routing: { plan: { model: "claude-sonnet-5-5", effort: "max" }, implement: { model: "nope", effort: "low" } } }
    assert_redirected_to work_queue_settings_path
    table = WorkQueue::RunState.routing
    assert_equal "claude-sonnet-5-5", table["plan"]["model"]
    assert_equal "claude-sonnet-5-5", table["implement"]["model"]
  end

  test "index lists items and lazy-loads the selected detail; sidebar defaults to collapsed" do
    calls = 0
    git = WorkQueue::GitInfo.singleton_class
    git.alias_method(:orig_compute, :compute)
    git.define_method(:compute) { |*| calls += 1 }
    get work_queue_path(item: "home-me-app:1")
    git.alias_method(:compute, :orig_compute)
    assert_equal 0, calls
    assert_response :ok
    assert_select "turbo-frame#wq_detail[src=?]", work_queue_item_detail_path("home-me-app:1")
    assert_select ".wq-detail-grid", 0
    assert_select "[data-sidebar-default-value=collapsed]"
  end

  test "detail explains a missing log" do
    get work_queue_item_detail_path("home-me-app:1")
    assert_response :ok
    assert_select ".wq-log .wq-empty", text: /Not started yet|no transcript found/
  end

  test "questions without options show cached suggestion chips" do
    WorkQueue::QueueWriter.new(dir: @dir).ask("home-me-app", 1, [{ q: "Which DB?" }])
    WorkQueue::RunState.redis.set(WorkQueue::Suggestions.cache_key("Which DB?"), %w[Postgres MySQL].to_json)
    get work_queue_item_detail_path("home-me-app:1")
    assert_select ".wq-qbox .wq-chip", text: /Postgres/
    assert_select ".wq-qbox input[type=radio][name='answers[0]'][value=Postgres]"
    assert_select ".wq-qbox .wq-free textarea[name='custom[0]']"
  end

  test "settings edit a project's always-allow rules" do
    WorkQueue::RunState.save_project("home-me-app", "always_allow" => ["Bash(ls:*)", "WebFetch"])
    get work_queue_settings_path(slug: "home-me-app")
    assert_select "input[name='rules[]'][value='Bash(ls:*)']"
    patch work_queue_settings_path, params: { slug: "home-me-app", rules: ["", "Bash(ls -la:*)", "WebFetch"],
                                              delete_rules: ["WebFetch"], new_rules: "Bash(git push:*)\nbad rule ((" }
    assert_redirected_to work_queue_settings_path(slug: "home-me-app")
    assert_equal ["Bash(ls -la:*)", "Bash(git push:*)"], WorkQueue::RunState.project("home-me-app")["always_allow"]
  end
end
