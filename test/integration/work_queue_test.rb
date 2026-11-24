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
    assert_select "li:has(> #wq_item_home-me-app_7) > ul#wq_kids_home-me-app_7 > li > .wq-card.wq-node-child", 2
    assert_select "li.wq-li-parent:has(> #wq_item_home-me-app_7) > button.wq-twisty[aria-expanded=true][aria-controls=wq_kids_home-me-app_7]"
    assert_select "#wq_item_home-me-app_7.wq-node-root .wq-kid-sum", text: "0 of 2 child steps done · 2 need you"
    assert_select "#wq_item_home-me-app_7 .wq-node-q", text: "2 ?"
    assert_select "#wq_item_home-me-app_7 .wq-card-link[aria-current=true]"
    assert_select "form[action=?]", work_queue_item_run_path("home-me-app:8")
  end

  test "cards show a progress bar; parents roll up their child steps" do
    get work_queue_path
    bar = ->(n) { css_select("#wq_item_home-me-app_#{n} .wq-prog-bar[role=progressbar]").first }
    assert_equal "28", bar.(7)["aria-valuenow"] # (17 own + 67 + 0) / 3
    assert_equal "Task 7 with its child steps", bar.(7)["aria-label"]
    assert_select "#wq_item_home-me-app_7 .wq-prog-n", text: "28%"
    assert_equal "67", bar.(9)["aria-valuenow"]
    assert_equal "0", bar.(8)["aria-valuenow"]
    assert_select "#wq_item_home-me-app_11 .wq-prog-ok .wq-prog-n", text: "100%"
    assert_select "#wq_item_home-me-app_8 .wq-kid-sum", 0
    assert_select "#wq_item_home-me-app_12 .wq-prog", 0 # folded: no progress
  end

  test "a finished parent with open child steps says so, sorts with open work and links what needs you" do
    File.write(File.join(@dir, "home-me-app.json"), {
      items: [{ n: 1, title: "Old done", status: "done", questions: [], log: [] },
              { n: 2, title: "Parent shipped", status: "done", questions: [], log: [] },
              { n: 3, title: "Kid building", status: "running", parent: 2, questions: [], log: [{ at: 1, text: "→ running" }] },
              { n: 4, title: "Kid asks", status: "blocked", parent: 2, questions: [{ q: "Which?" }], log: [] },
              { n: 5, title: "Newer done", status: "done", questions: [], log: [] }]
    }.to_json)
    get work_queue_path
    assert_select "#wq_item_home-me-app_2 .wq-node-l", text: "Live · 2 child steps still in progress"
    assert_select "#wq_item_home-me-app_2 .wq-prog-run .wq-prog-n", text: "47%" # (100 + 25 + 17) / 3
    roots = css_select("#wq_project_home-me-app > .wq-tree > ul > li > .wq-card").map { |c| c["data-n"] }
    assert_equal %w[2 5 1], roots

    get work_queue_item_detail_path("home-me-app:2")
    assert_select ".wq-flow-head .wq-pill-run", text: "2 child steps still in progress"
    assert_select ".wq-overall .wq-prog-lg .wq-prog-n", text: "47%"
    assert_select ".wq-overall .wq-hint", text: /This task 100% · child steps 0 of 2 done/
    assert_select ".wq-kid-note", text: /2 child steps below are not/
    assert_select ".wq-your-part", text: /1 child step needs you/
    assert_select ".wq-your-part a.wq-ref[href=?]", work_queue_item_detail_path("home-me-app:4"), text: "#4 Needs your answer"
    assert_select "#wq_kid_home-me-app_3 .wq-prog-bar[aria-valuenow='25']"
    assert_select "#wq_kid_home-me-app_3 .wq-rel-l", text: "Building"

    get work_queue_item_detail_path("home-me-app:3")
    assert_select ".wq-now .wq-summary", text: "Building now."
    assert_select ".wq-overall .wq-hint", text: /phase 2 of 6/
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
    assert_select ".wq-now .wq-step[aria-current=step]", text: "Merged"
    assert_select ".wq-now .wq-step-done", 4 # plan, build, test, PR
    assert_select ".wq-related .wq-rel-kind", text: "Parent task"
    assert_select ".wq-related .wq-rel-kind", text: "Sibling"
    assert_select ".wq-actions a.wq-btn[href='https://github.com/o/r/pull/12']", text: "Open PR #12"
    assert_select ".wq-actions button[disabled][title=?]", "Waiting on #7", text: "Merge"
    assert_select ".wq-actions button[disabled]", text: "Deploy"
    assert_empty css_select("[onclick], [data-turbo-confirm]")

    get work_queue_item_detail_path("home-me-app:10")
    assert_select ".wq-actions form[action=?] button", work_queue_item_run_path("home-me-app:10"), text: "Approve & queue"

    get work_queue_item_detail_path("home-me-app:7")
    assert_select ".wq-qbox h3", text: "2 questions for you"
    assert_select ".wq-qbox input[type=radio][name='answers[0]'][value=red]"
    assert_select ".wq-qbox .wq-chip-rec", text: /red \(suggested\)/
    assert_select ".wq-qbox textarea[name='custom[1]']"
    assert_select ".wq-qbox button[type=submit]", text: "Send answers"
    assert_select ".wq-now .wq-kid-steps li", 2 do |kids|
      assert_includes kids.text, "#9 Follow on"
      assert_includes kids.text, "Ready to merge"
    end
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

  test "add child item queues a follow-up under this item without approval" do
    post work_queue_item_children_path("home-me-app:1"), params: { title: "Child bit", description: "details" }, as: :turbo_stream
    assert_response :ok
    item = WorkQueue::Store.new.find("home-me-app:2")
    assert_equal [1, "queued", false, "details"], [item.parent, item.status, item.awaiting_approval, item.description]
    job = JSON.parse(WorkQueue::RunState.redis.lpop(WorkQueue::RunState::JOBS))
    assert_equal %w[start home-me-app:2], [job["action"], job["key"]]
  end

  test "a stalled running item reads Stalled, counts as failed, and Resume hands it to the runner" do
    at = (3.hours.ago.to_f * 1000).to_i
    File.write(File.join(@dir, "home-me-stall.json"), { items: [
      { n: 1, title: "Went quiet", status: "running", questions: [], log: [{ at: at, text: "→ running" }], createdAt: at, updatedAt: at },
      { n: 2, title: "Still going", status: "running", questions: [], log: [], updatedAt: (Time.current.to_f * 1000).to_i }
    ] }.to_json)

    get work_queue_path
    assert_select "#wq_item_home-me-stall_1[data-tone=bad][data-tags~=stalled][data-tags~=you][data-tags~=bad] .wq-node-l", text: "Stalled: no activity for 3h"
    assert_select "#wq_item_home-me-stall_1 form[action=?]", work_queue_item_resume_path("home-me-stall:1")
    assert_select "#wq_item_home-me-stall_1 .wq-prog-bad"
    assert_select "#wq_project_home-me-stall .wq-pb-bad", text: "1 failed"
    assert_select "#wq_item_home-me-stall_2[data-tone=run] .wq-node-l", text: "Building"
    assert_select "#wq_item_home-me-stall_2 form[action=?]", work_queue_item_resume_path("home-me-stall:2"), count: 0

    get work_queue_item_detail_path("home-me-stall:1")
    assert_select ".wq-actions form[action=?] button", work_queue_item_resume_path("home-me-stall:1"), text: "Resume"
    assert_select ".wq-now", text: /Your part:\s*Resume it, or tell the agent what to do\./

    WorkQueue::RunState.set("home-me-stall:1", { "mode" => "build", "phase" => "implement" })
    post work_queue_item_resume_path("home-me-stall:1"), as: :turbo_stream
    assert_response :ok
    job = JSON.parse(WorkQueue::RunState.redis.lpop(WorkQueue::RunState::JOBS))
    assert_equal %w[start home-me-stall:1 implement], [job["action"], job["key"], job["phase"]]
    item = WorkQueue::Store.new.find("home-me-stall:1")
    assert_equal "Resumed from myjira after a stall", item.log.last["text"]
    assert_not WorkQueue::Flow.new(item).stalled?
  end

  test "ready for PR asks the runner to bundle now" do
    WorkQueue::QueueWriter.new(dir: @dir).update("home-me-app", 1) do |i|
      i["status"] = "review"
      i["branch"] = "wq/1"
      i["readyToBundle"] = true
    end
    get work_queue_item_detail_path("home-me-app:1")
    assert_select ".wq-actions form[action=?] button", work_queue_item_ship_path("home-me-app:1"), text: "Ready for PR"
    post work_queue_item_ship_path("home-me-app:1"), as: :turbo_stream
    job = JSON.parse(WorkQueue::RunState.redis.lpop(WorkQueue::RunState::JOBS))
    assert_equal %w[bundle home-me-app:1], [job["action"], job["key"]]
  end

  test "deploy refuses an unmerged PR" do
    WorkQueue::QueueWriter.new(dir: @dir).update("home-me-app", 1) { |i| i["pr"] = "https://github.com/o/r/pull/3" }
    WorkQueue::PullRequests.stub(:new, Struct.new(:x) { def fetch(_) = nil }.new) do
      post work_queue_item_deploy_path("home-me-app:1"), as: :turbo_stream
    end
    assert_includes response.body, "not merged"
  end

  test "new follow-ups are not gated on approval" do
    WorkQueue::QueueWriter.new(dir: @dir).add("home-me-app", title: "Child", parent: 1)
    assert_not WorkQueue::Store.new.find("home-me-app:2").awaiting_approval
  end

  test "run now approves a follow-up awaiting approval" do
    w = WorkQueue::QueueWriter.new(dir: @dir)
    w.add("home-me-app", title: "Follow-up", parent: 1)
    w.update("home-me-app", 2) { |i| i["awaitingApproval"] = true }
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

  test "an instruction carries dropped or pasted files as saved paths" do
    Tempfile.create(["notes", ".md"]) do |f|
      f.write("# notes")
      f.flush
      upload = Rack::Test::UploadedFile.new(f.path, "text/markdown", original_filename: "notes.md")
      post work_queue_item_instruct_path("home-me-app:1"), params: { text: "use these", files: [upload] }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    assert_response :ok
    saved = File.join(@dir, "attachments", "home-me-app", "1", "notes.md")
    assert File.exist?(saved)
    assert_includes WorkQueue::Store.new.find("home-me-app:1").description, "Attached files:\n#{saved}"
  end

  test "a new item rejects file types that are not images, PDFs or text" do
    Tempfile.create(["tool", ".exe"]) do |f|
      upload = Rack::Test::UploadedFile.new(f.path, "application/octet-stream", original_filename: "tool.exe")
      post work_queue_items_path, params: { slug: "home-me-app", text: "With a binary", files: [upload] }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    assert_response :ok
    assert_not Dir.exist?(File.join(@dir, "attachments", "home-me-app", "2"))
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

  test "suggestion chips have stable ids across re-renders" do
    WorkQueue::QueueWriter.new(dir: @dir).ask("home-me-app", 1, [{ q: "Which DB?" }])
    WorkQueue::RunState.redis.set(WorkQueue::Suggestions.cache_key("Which DB?"), %w[Postgres MySQL].to_json)
    ids = 2.times.map do
      get work_queue_item_detail_path("home-me-app:1")
      assert_select ".wq-qbox .wq-chips[data-work-queue-target=suggestions][data-item-key='home-me-app:1']"
      css_select(".wq-qbox .wq-chips input.wq-chip-input").map { |el| el["id"] }
    end
    assert_equal 2, ids.first.size
    assert ids.first.all? { |id| id.start_with?("wq_sugg_home-me-app-1_0_") }
    assert_equal ids.first.uniq, ids.first
    assert_equal ids.first, ids.last
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

  test "flagging an item as a browser step shows Run in Chrome, and the reason when nothing can run it" do
    get work_queue_item_detail_path("home-me-app:1")
    assert_select "form[action=?]", work_queue_item_run_in_chrome_path("home-me-app:1"), 0
    post work_queue_item_browser_path("home-me-app:1"), params: { value: "1" }, as: :turbo_stream
    SessionLaunch.stub(:launcher_alive?, false) do
      get work_queue_item_detail_path("home-me-app:1")
      assert_select "form[action=?] button.wq-btn-chrome", work_queue_item_run_in_chrome_path("home-me-app:1"), text: /Run in Chrome/
      assert_select ".wq-chrome-blocked", text: /launcher daemon is down/
      post work_queue_item_run_in_chrome_path("home-me-app:1"), as: :turbo_stream
      assert_match(/Not sent:.*isn&#39;t polling|Not sent:.*isn't polling/, response.body)
      assert_match(/Copy command/, response.body)
    end
  ensure
    WorkQueue::RunState.del_fields("home-me-app:1", "browser")
  end
end
