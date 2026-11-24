require "test_helper"
require "rake"

# The inbox is the home page: Work Queue items waiting on the person, answerable in place.
class InboxTest < ActionDispatch::IntegrationTest
  PERMISSION = ["Allow once", "Always allow in this project", "Deny"].freeze

  setup do
    @dir = Dir.mktmpdir("wq-inbox")
    @old = ENV["WORK_QUEUE_DIR"]
    ENV["WORK_QUEUE_DIR"] = @dir
    redis = WorkQueue::RunState.redis
    redis.scan_each(match: "#{WorkQueue::RunState::PREFIX}:*") { |k| redis.del(k) }
    old = ((Time.current - 4.days).to_f * 1000).to_i
    recent = ((Time.current - 20.minutes).to_f * 1000).to_i
    File.write(File.join(@dir, "home-me-app.json"), {
      items: [
        { n: 1, title: "Pick a colour", status: "blocked", updatedAt: old, createdAt: old, log: [],
          questions: [{ q: "Which colour?", at: old, options: %w[red blue] }] },
        { n: 2, title: "Run the specs", status: "blocked", updatedAt: recent, createdAt: recent, log: [],
          questions: [{ q: "Permission: Bash bundle exec rspec spec/a_spec.rb?", at: recent, options: PERMISSION },
                      { q: "Permission: Bash bin/rubocop app?", at: recent, options: PERMISSION }] },
        { n: 3, title: "A suggested follow-up", status: "triage", awaitingApproval: true, updatedAt: recent, createdAt: recent, questions: [], log: [] },
        { n: 4, title: "Went quiet", status: "running", updatedAt: old, createdAt: old, questions: [], log: [] },
        { n: 5, title: "Shipped", status: "done", updatedAt: recent, createdAt: recent, questions: [], log: [] }
      ]
    }.to_json)
  end

  teardown do
    ENV["WORK_QUEUE_DIR"] = @old
    FileUtils.rm_rf(@dir)
  end

  test "the home page is the inbox and the projects list stays at /projects" do
    get root_path
    assert_response :success
    assert_select "h1", text: "Inbox"
    assert_select "turbo-frame#inbox_frame[target='_top']"
    get projects_path
    assert_response :success
    get inbox_path
    assert_response :success
  end

  test "a decision renders the question box posting to the existing answer endpoint" do
    get inbox_path
    assert_select "#inbox_s_decisions #inbox_home-me-app_1" do
      assert_select "form[action='#{work_queue_item_answer_path('home-me-app:1')}']" do
        assert_select "input[type=radio][name='answers[0]'][value='red']"
        assert_select "textarea[name='custom[0]']"
      end
      assert_select ".wq-wait.wq-wait-late", text: /waiting 4d/
      assert_select "a.inbox-entry-title[href='#{work_queue_path(item: 'home-me-app:1')}']", text: /Pick a colour/
    end
    post work_queue_item_answer_path("home-me-app:1"), params: { answers: { "0" => "red" } }, as: :turbo_stream
    assert_response :ok
    assert_equal "red", WorkQueue::Store.new.find("home-me-app:1").questions.first.a
    get inbox_path
    assert_select "#inbox_home-me-app_1", 0
  end

  test "permission prompts, approvals and stalled tasks get their one-click actions" do
    get inbox_path
    assert_select "#inbox_s_permissions #inbox_home-me-app_2 button[name='allow_all']"
    assert_select "#inbox_s_approve #inbox_home-me-app_3 form[action='#{work_queue_item_run_path('home-me-app:3')}'] button", text: "Approve & queue"
    assert_select "#inbox_s_stalled #inbox_home-me-app_4 form[action='#{work_queue_item_resume_path('home-me-app:4')}'] button", text: "Resume"
    assert_select "#inbox_home-me-app_5", 0
    assert_select ".inbox-strip a.inbox-strip-i", text: "1 decision"
    assert_select ".inbox-strip a.inbox-strip-i", text: "2 permission prompts"
    assert_select ".inbox-strip a.inbox-strip-late", text: "2 waiting over 3 days"
  end

  test "sidebar leads with Inbox and its count, red when something is over three days" do
    get documents_path
    assert_select "#app-sidebar nav[aria-label='Main'] a.clink:first-of-type[href='#{inbox_path}']" do
      assert_select "span.truncate", text: "Inbox"
      assert_select "#sidebar_inbox_count", text: "4"
      assert_select "#sidebar_inbox_count[class*='fail-ink']"
    end
  end

  test "an empty inbox says nothing needs you" do
    FileUtils.rm_f(Dir.glob(File.join(@dir, "*.json")))
    get inbox_path
    assert_select ".inbox-clear", text: /Nothing needs you/
    assert_select ".inbox-strip", 0
  end

  test "work queue cards and the detail pill show how long an item has waited" do
    get work_queue_path
    assert_select "#wq_item_home-me-app_1 .wq-wait.wq-wait-late", text: /4d/
    assert_select "#wq_item_home-me-app_4 .wq-wait", 0, "a stalled card already says how long in its label"
    get work_queue_item_detail_path("home-me-app:1")
    assert_select "#wq_log_header .wq-wait", text: /waiting 4d/
  end

  test "approvals and review point at the inbox" do
    get approvals_path
    assert_select "a[href='#{inbox_path}']", text: "Inbox"
    get review_path
    assert_select "a[href='#{inbox_path}']", text: "Inbox"
  end

  test "inbox:summary prints the summary and the oldest waits" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("inbox:summary")
    task = Rake::Task["inbox:summary"]
    task.reenable
    out, = capture_io { task.invoke }
    assert_includes out, "Inbox: 1 decision · 2 permission prompts · 1 to approve · 1 stalled · 2 waiting over 3 days"
    assert_match(/waiting 4d \d+h: app #1 Pick a colour/, out)
    assert_not_includes out, "Push:"
  end
end
