require "test_helper"

# The task list draws only the work still going plus a few recent finished tasks;
# the rest load on demand, and the filter totals stay true either way.
class WorkQueueOlderTest < ActionDispatch::IntegrationTest
  SLUG = "home-me-app".freeze

  setup do
    @dir = Dir.mktmpdir("wq")
    done = (1..8).map { |n| { n: n, title: "Done #{n}", status: "done", questions: [], log: [], updatedAt: n * 1000 } }
    File.write(File.join(@dir, "#{SLUG}.json"), { items: done + [
      { n: 9, title: "Shipped parent", status: "done", questions: [], log: [], updatedAt: 1 },
      { n: 10, title: "Open kid", status: "queued", parent: 9, questions: [], log: [] },
      { n: 11, title: "Done kid", status: "done", parent: 9, questions: [], log: [], updatedAt: 9000 }
    ] }.to_json)
    @old = ENV["WORK_QUEUE_DIR"]
    ENV["WORK_QUEUE_DIR"] = @dir
  end

  teardown do
    ENV["WORK_QUEUE_DIR"] = @old
    FileUtils.rm_rf(@dir)
  end

  def cards = css_select("#wq_project_#{SLUG} .wq-card").map { |c| c["data-n"].to_i }.sort

  test "the list draws open work, its finished parents and the five newest finished tasks" do
    get work_queue_path
    assert_response :ok
    assert_equal [4, 5, 6, 7, 8, 9, 10], cards
    assert_select "#wq_project_#{SLUG}[data-older='4'][data-all=false][data-older-url=?]", work_queue_project_path(SLUG)
    assert_select "#wq_project_#{SLUG} button.wq-older", text: "Show 4 older finished tasks"
    assert_select "#wq_item_#{SLUG}_9 .wq-kid-sum", text: "1 of 2 child steps done", count: 1
  end

  test "filter totals come from the server and count tasks that are not drawn" do
    get work_queue_path
    counts = JSON.parse(css_select("#wq_proj_cnt_#{SLUG}[data-work-queue-target=counts]").first["data-counts"])
    assert_equal 1, counts["all"]
    assert_equal 10, counts["ok"], "all ten finished tasks, though only six are in the page"
    assert_select "#wq_proj_sub_#{SLUG}", text: "1 open · 10 done"
  end

  test "an old selected task is drawn" do
    get work_queue_path(item: "#{SLUG}:2")
    assert_includes cards, 2
    assert_select "#wq_item_#{SLUG}_2 .wq-card-link[aria-current=true]"
    assert_select "#wq_project_#{SLUG}[data-older='3']"
  end

  test "older=1 returns the whole project block; older=0 the default cut" do
    get work_queue_project_path(SLUG, older: 1), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :ok
    assert_select "turbo-stream[action=replace][target=wq_project_#{SLUG}]"
    assert_select "template .wq-card", 11
    assert_select "template #wq_project_#{SLUG}[data-all=true] button.wq-older", text: "Hide 4 older finished tasks"
    assert_select "template ul#wq_kids_#{SLUG}_9 > li > .wq-card", 2

    get work_queue_project_path(SLUG, older: 0), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_select "template .wq-card", 7
  end

  test "unknown or malformed project slugs are not found" do
    get work_queue_project_path("nope"), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :not_found
  end

  test "the new-item project picker leaves out archived projects and agent worktrees" do
    Project.create!(name: "Live repo", repo_path: "/srv/live-repo")
    Project.create!(name: "Shelved repo", repo_path: "/srv/shelved-repo", archived_at: Time.current)
    Project.create!(name: "Agent copy").update_column(:repo_path, "/srv/live-repo/.claude/worktrees/agent-abc")
    labels = WorkQueue::Workspace.choices.map(&:first)
    assert_includes labels, "Live repo"
    assert_not_includes labels, "Shelved repo"
    assert_not_includes labels, "Agent copy"
  end
end
