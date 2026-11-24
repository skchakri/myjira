require "test_helper"
require "rake"

# The "Yours" endpoints and markup: mark, tick off, snooze, due date, unmark, hand to an agent.
class ErrandsTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  SLUG = "home-me-app".freeze
  STREAM = { "Accept" => "text/vnd.turbo-stream.html" }.freeze

  setup do
    @dir = Dir.mktmpdir("wq-errands")
    @old = ENV["WORK_QUEUE_DIR"]
    ENV["WORK_QUEUE_DIR"] = @dir
    redis = WorkQueue::RunState.redis
    redis.scan_each(match: "#{WorkQueue::RunState::PREFIX}:*") { |k| redis.del(k) }
    Rails.cache.delete(WorkQueue::Inbox::COUNT_CACHE)
    at = ((Time.current - 2.days).to_f * 1000).to_i
    File.write(File.join(@dir, "#{SLUG}.json"), {
      items: [
        { n: 1, title: "A thru Z: confirm with the practice about closing time", status: "blocked", questions: [],
          log: [{ at: at, text: "→ blocked" }], createdAt: at, updatedAt: at },
        { n: 2, title: "Build the thing", status: "queued", questions: [], log: [], createdAt: at, updatedAt: at },
        { n: 3, title: "Collect the receipts", status: "review", kind: "yours", yoursAt: at, questions: [], log: [], createdAt: at, updatedAt: at }
      ]
    }.to_json)
  end

  teardown do
    ENV["WORK_QUEUE_DIR"] = @old
    FileUtils.rm_rf(@dir)
  end

  def find(n) = WorkQueue::Store.new.find("#{SLUG}:#{n}")
  def errand(n, **params) = post(work_queue_item_errand_path("#{SLUG}:#{n}"), params: params, headers: STREAM)
  def jobs = WorkQueue::RunState.redis.lrange(WorkQueue::RunState::JOBS, 0, -1).map { |j| JSON.parse(j) }

  test "mark keeps the status, done ticks it off, unmark puts it back" do
    errand(1, op: "mark")
    assert_response :ok
    marked = find(1)
    assert marked.yours?
    assert_equal "blocked", marked.status
    assert marked.yours_at.present?

    errand(1, op: "done")
    done = find(1)
    assert_equal "done", done.status
    assert_includes done.log.map { |l| l["text"] }, "Done by you"

    errand(3, op: "unmark")
    back = find(3)
    assert_not back.yours?
    assert_equal "review", back.status
    assert_empty jobs, "unmarking starts nothing"
  end

  test "snooze and due date are stored; a bad or past day is refused" do
    travel_to Time.zone.local(2026, 11, 24, 10) do
      errand(3, op: "snooze", until: "monday")
      assert_equal Time.zone.local(2026, 11, 30, 8), find(3).snoozed_until
      assert find(3).snoozed?

      errand(3, op: "wake")
      assert_not find(3).snoozed?

      errand(3, op: "snooze", date: "2026-11-01")
      assert_match(/Pick a day in the future/, response.body)
      assert_nil find(3).snoozed_until

      errand(3, op: "due", date: "2026-11-28")
      assert_equal Date.new(2026, 11, 28), find(3).due
      errand(3, op: "due", date: "nonsense")
      assert_equal Date.new(2026, 11, 28), find(3).due
      errand(3, op: "due", date: "")
      assert_nil find(3).due
    end
  end

  test "hand to an agent unmarks, queues and starts it; an errand cannot be run or handled when not marked" do
    post work_queue_item_run_path("#{SLUG}:3"), headers: STREAM
    assert_match(/is an errand for you/, response.body)
    assert_empty jobs

    errand(2, op: "done")
    assert_match(/not marked as yours/, response.body)
    assert_equal "queued", find(2).status

    errand(3, op: "hand")
    handed = find(3)
    assert_not handed.yours?
    assert_equal "queued", handed.status
    assert_equal [["start", "#{SLUG}:3"]], jobs.map { |j| j.values_at("action", "key") }
  end

  test "the composer files an errand that is never started, and the bulk bar marks ticked tasks" do
    post work_queue_items_path, params: { slug: SLUG, text: "Call the bank about the wire", yours: "1", start: "1" }, headers: STREAM
    filed = find(4)
    assert filed.yours?
    assert_equal "queued", filed.status
    assert_empty jobs

    post work_queue_errands_path, params: { keys: ["#{SLUG}:1", "#{SLUG}:2", "#{SLUG}:3"] }, headers: STREAM
    assert_match(/Marked #1, #2 as yours/, response.body)
    assert find(1).yours? && find(2).yours?
  end

  test "the list and detail pane show an errand as a checkbox, not agent phases" do
    get work_queue_path
    assert_select "#wq_item_#{SLUG}_3 .wq-t-mine"
    assert_select "#wq_item_#{SLUG}_3 form[action$='/errand'] .wq-errand-box"
    assert_select "#wq_item_#{SLUG}_3 form[action$='/run']", 0
    assert_select ".wq-tab[data-f=yours]"
    assert_select "#wq_proj_cnt_#{SLUG}[data-counts*='\"yours\":1']"
    assert_select "form.wq-composer-form input[name=yours]"

    get work_queue_item_detail_path("#{SLUG}:3")
    assert_select ".wq-pill-mine", text: "Yours"
    assert_select ".wq-errand-row .wq-errand-done"
    assert_select "ol.wq-path", 0
    assert_select ".wq-errand form[action$='/errand'] input[name=op][value=hand]"
    assert_select "form[action$='/run']", 0

    get work_queue_item_detail_path("#{SLUG}:1")
    assert_select ".wq-errand-hint", text: /Looks like an errand/
    assert_select "form[action$='/errand'] input[name=op][value=mark]", minimum: 2 # the hint and "Mine to do"
    assert_select "ol.wq-path"

    errand(1, op: "dismiss_hint")
    get work_queue_item_detail_path("#{SLUG}:1")
    assert_select ".wq-errand-hint", 0
    get work_queue_item_detail_path("#{SLUG}:2")
    assert_select ".wq-errand-hint", 0
  end

  test "the inbox has a Yours section with the actions, a hint on look-alikes, and a snoozed disclosure" do
    get inbox_path
    assert_select "#inbox_s_yours .inbox-entry[data-section=yours]", 1
    assert_select "#inbox_s_yours .wq-errand form[action$='/errand']"
    assert_select "#inbox_s_failed .wq-errand-hint"
    assert_select ".inbox-strip-i", text: "1 yours"
    assert_select "#sidebar_inbox_count", text: "1" # the stuck task; an errand with no due date is not counted

    errand(3, op: "snooze", until: "3d")
    Rails.cache.delete(WorkQueue::Inbox::COUNT_CACHE)
    get inbox_path
    assert_select ".inbox-entry[data-section=yours]", 0
    assert_select ".inbox-snoozed summary", text: "1 snoozed"
    assert_select ".inbox-snoozed form[action$='/errand'] input[name=op][value=wake]"
  end

  test "the morning summary lists errands due today or overdue" do
    errand(3, op: "due", date: 2.days.ago.to_date.iso8601)
    Rails.application.load_tasks unless Rake::Task.task_defined?("inbox:summary")
    Rake::Task["inbox:summary"].reenable
    out, = capture_io { Rake::Task["inbox:summary"].invoke }
    assert_match(/1 yours \(1 overdue\)/, out)
    assert_match(/yours, overdue 2d: .* #3 Collect the receipts/, out)
  end
end
