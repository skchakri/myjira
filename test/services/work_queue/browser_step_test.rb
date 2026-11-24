require "test_helper"

class WorkQueueBrowserStepTest < ActiveSupport::TestCase
  Item = WorkQueue::Store::Item

  def item(title, description: "", n: 7, session: nil, repo: nil)
    Item.new(slug: "tmp-wqchrome", n: n, title: title, description: description, status: "blocked",
             questions: [], log: [], session: session, repo: repo)
  end

  teardown do
    WorkQueue::Broadcaster.redis.del(SessionLaunch::LAUNCHER_SEEN_KEY)
    WorkQueue::Broadcaster.redis.del("#{WorkQueue::RunState::PREFIX}:run:tmp-wqchrome:7")
  end

  test "detects browser steps from item text" do
    assert WorkQueue::BrowserStep.detect?("Get TikTok video.upload scope approved on developers.tiktok.com")
    assert WorkQueue::BrowserStep.detect?("Open https://example.com/settings and copy the key")
    assert WorkQueue::BrowserStep.detect?("Use Chrome to check the page")
    assert WorkQueue::BrowserStep.detect?("Upload the build in the partner portal")
    assert_not WorkQueue::BrowserStep.detect?("Add a migration for the users table")
    assert_not WorkQueue::BrowserStep.detect?("Open the file and fix the lint")
  end

  test "explicit flag wins over detection both ways" do
    plain = item("Refactor the model")
    tiktok = item("Get TikTok developer portal approval")
    assert_nil WorkQueue::BrowserStep.reason(plain, {})
    assert_equal :flag, WorkQueue::BrowserStep.reason(plain, { "browser" => "1" })
    assert_equal :detected, WorkQueue::BrowserStep.reason(tiktok, {})
    assert_nil WorkQueue::BrowserStep.reason(tiktok, { "browser" => "0" })
  end

  test "run_in_chrome goes to the listening CLI with a controller-mode instruction" do
    project = Project.create!(name: "WQC", slug: "wqc-#{SecureRandom.hex(3)}", repo_path: "/tmp/wqc-#{SecureRandom.hex(3)}")
    convo = project.conversations.create!(session_id: "s-#{SecureRandom.hex(4)}", started_at: 1.minute.ago,
                                          last_message_at: 1.minute.ago, listener_seen_at: 5.seconds.ago)
    r = WorkQueue::Dispatcher.new(item("TikTok scope", session: convo.session_id)).run_in_chrome
    assert r.sent
    assert_includes convo.session_commands.last.body, "myjira-relay"
    assert_includes convo.session_commands.last.body, "controller mode"
  end

  test "run_in_chrome launches an interactive chrome session when the CLI is offline and the daemon is up" do
    repo = "/tmp/wqc-#{SecureRandom.hex(3)}"
    Project.create!(name: "WQL", slug: "wql-#{SecureRandom.hex(3)}", repo_path: repo)
    SessionLaunch.launcher_seen!
    r = WorkQueue::Dispatcher.new(item("TikTok scope", repo: repo)).run_in_chrome
    assert r.sent
    assert r.launch.chrome
    assert_equal repo, r.launch.repo_path
    assert_includes r.launch.prompt, "controller mode"
    assert_not r.duplicate

    again = WorkQueue::Dispatcher.new(item("TikTok scope", repo: repo)).run_in_chrome
    assert again.sent
    assert again.duplicate
    assert_equal r.launch, again.launch
    assert_equal 1, SessionLaunch.where(repo_path: repo).count
  end

  test "an active chrome launch is pending, launching or recently launched" do
    project = Project.create!(name: "WQA", slug: "wqa-#{SecureRandom.hex(3)}", repo_path: "/tmp/wqa-#{SecureRandom.hex(3)}")
    launch = SessionLaunch.queue!(project: project, prompt: "go", chrome: true)
    run = { WorkQueue::ChromeRun::FIELD => launch.id }
    assert_equal launch, WorkQueue::ChromeRun.active_launch(run)
    launch.update!(status: "launched", launched_at: 5.minutes.ago)
    assert_equal launch, WorkQueue::ChromeRun.active_launch(run)
    launch.update!(launched_at: (WorkQueue::ChromeRun::WINDOW + 1.minute).ago)
    assert_nil WorkQueue::ChromeRun.active_launch(run)
    launch.update!(status: "failed")
    assert_nil WorkQueue::ChromeRun.active_launch(run)
    assert_nil WorkQueue::ChromeRun.active_launch({})
    assert_nil WorkQueue::ChromeRun.active_launch({ WorkQueue::ChromeRun::FIELD => SecureRandom.uuid })
  end

  test "run_in_chrome explains why when no chrome-capable path exists" do
    repo = "/tmp/wqc-#{SecureRandom.hex(3)}"
    Project.create!(name: "WQD", slug: "wqd-#{SecureRandom.hex(3)}", repo_path: repo)
    SessionLaunch.stub(:launcher_alive?, false) do
      r = WorkQueue::Dispatcher.new(item("TikTok scope", repo: repo)).run_in_chrome
      assert_not r.sent
      assert_match(/isn't polling/, r.reason)
      assert_match(/no live CLI session/, r.reason)
      assert_match(%r{\A/item7 }, r.copy)
    end
  end
end
