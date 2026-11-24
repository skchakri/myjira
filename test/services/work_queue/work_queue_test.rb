require "test_helper"

class WorkQueueServicesTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir("wq")
    @projects = Dir.mktmpdir("wqp")
    File.write(File.join(@dir, "home-me-proj.json"), {
      items: [
        { n: 1, title: "Parent", status: "review", pr: "https://github.com/o/r/pull/10", questions: [], log: [], updatedAt: 5 },
        { n: 2, title: "Child", status: "review", parent: 1, pr: "https://github.com/o/r/pull/11", questions: [], log: [] },
        { n: 3, title: "Ask", status: "blocked", session: "s1", agent: "abc",
          questions: [{ q: "Which db?", options: %w[pg mysql] }], log: [] },
        { n: 4, title: "Later", status: "triage", awaitingApproval: true, questions: [], log: [] },
        { n: 5, title: "Gone", status: "merged", questions: [], log: [] }
      ]
    }.to_json)
    @store = WorkQueue::Store.new(dir: @dir)
  end

  teardown do
    FileUtils.rm_rf(@dir)
    FileUtils.rm_rf(@projects)
  end

  test "maps mod statuses to display statuses" do
    by_n = @store.items_for("home-me-proj").index_by(&:n)
    assert_equal "review", by_n[1].display_status
    assert_equal "waiting", by_n[3].display_status
    assert_equal "pending", by_n[4].display_status
    assert_equal "done", by_n[5].display_status
    assert_equal "10", by_n[1].pr_number
  end

  test "find rejects path traversal and resolves keys" do
    assert_equal "Ask", @store.find("home-me-proj:3").title
    assert_nil @store.find("../etc:1")
  end

  test "card merge hidden while a dependency is open; chain is parent first" do
    parent = @store.find("home-me-proj:1")
    child = @store.find("home-me-proj:2")
    ctx = WorkQueue::ItemContext.new(child, store: @store, prs: WorkQueue::PullRequests.new(runner: ->(*) { ["", false] }))
    assert_not ctx.card_merge?
    assert ctx.chain_merge?
    assert_equal [parent.n, child.n], ctx.chain.map(&:n)
  end

  test "transcript parser pairs tool calls with results and tails by offset" do
    path = File.join(@projects, "-p", "s1", "subagents", "agent-abc.jsonl")
    FileUtils.mkdir_p(File.dirname(path))
    lines = [
      { type: "user", cwd: "/tmp/wt", message: { content: "Do it" } },
      { type: "assistant", message: { content: [{ type: "text", text: "On it" },
                                                { type: "tool_use", id: "t1", name: "Bash", input: { command: "ls", description: "List" } }] } }
    ]
    File.write(path, lines.map(&:to_json).join("\n") + "\n")
    item = @store.find("home-me-proj:3")
    assert_equal path, WorkQueue::Transcript.path_for(item, root: Pathname(@projects))
    assert_equal "abc", WorkQueue::Transcript.agent_id(path)
    assert_equal "/tmp/wt", WorkQueue::Transcript.cwd_for(path)

    entries, offset = WorkQueue::Transcript.new.parse_file(path)
    assert_equal %w[prompt note tool], entries.map(&:kind)
    assert_equal "List", entries.last.title

    File.open(path, "a") { |f| f.write({ type: "user", message: { content: [{ type: "tool_result", tool_use_id: "t1", content: "a\nb" }] } }.to_json + "\n{\"partial") }
    more, = WorkQueue::Transcript.new.parse_file(path, from: offset)
    assert_equal ["result"], more.map(&:kind)
    assert_equal "t1", more.first.tool_use_id
  end

  test "merge to main retargets first; chain to main merges parent first" do
    calls = []
    runner = lambda do |*args|
      calls << args.first(3).join(" ")
      args[1] == "view" ? [{ number: 11, state: "OPEN", baseRefName: "feat/a", headRefName: "feat/b", url: "u" }.to_json, true] : ["", true]
    end
    prs = WorkQueue::PullRequests.new(runner: runner)
    Rails.cache.clear
    assert prs.merge_chain(%w[P C], target: "main").ok
    merged = calls.grep(/merge/).map(&:split).map(&:last)
    assert_equal %w[P C], merged
    assert calls.any? { |c| c.start_with?("pr edit") }

    calls.clear
    prs.merge_chain(%w[P C], target: "base")
    assert_equal %w[C P], calls.grep(/merge/).map(&:split).map(&:last)
  end

  test "dispatcher returns a copy command when the session is not listening" do
    item = @store.find("home-me-proj:3")
    r = WorkQueue::Dispatcher.new(item).answer(0, "pg")
    assert_not r.sent
    assert_equal "/item3 pg", r.copy
  end

  test "dispatcher queues a session command when the owning session listens" do
    project = Project.create!(name: "WQ", slug: "wq-#{SecureRandom.hex(3)}", repo_path: "/tmp/wq")
    convo = project.conversations.create!(session_id: "s1", started_at: 1.minute.ago, last_message_at: 1.minute.ago,
                                          listener_seen_at: 5.seconds.ago)
    item = @store.find("home-me-proj:3")
    r = WorkQueue::Dispatcher.new(item).run_now
    assert r.sent
    cmd = convo.session_commands.last
    assert_equal "work-queue", cmd.source
    assert_includes cmd.body, "Start item #3"
  end

  test "foreign_repo is set only when the item's repo differs from its project's" do
    item = WorkQueue::Store::Item.new(slug: "home-me-proj", n: 9, repo: "/home/me/other")
    assert_equal "/home/me/other", item.foreign_repo("/home/me/proj")
    assert_nil item.foreign_repo("/home/me/other")
    assert_nil WorkQueue::Store::Item.new(slug: "home-me-proj", n: 9).foreign_repo("/home/me/proj")
  end

  test "item sessions are told to pass repo for follow-ups in another repo" do
    assert_includes WorkQueue::Dispatcher::PROTOCOL_HINT, "pass repo"
    assert_includes WorkQueue::SessionRunner::QUESTION_PROTOCOL, "different repo"
  end
end
