require "test_helper"

class WorkQueueRunnerTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir("wq")
    @writer = WorkQueue::QueueWriter.new(dir: @dir)
    @store = WorkQueue::Store.new(dir: @dir)
    redis = WorkQueue::RunState.redis
    redis.scan_each(match: "#{WorkQueue::RunState::PREFIX}:*") { |k| redis.del(k) }
  end

  teardown { FileUtils.rm_rf(@dir) }

  test "writer keeps the mod's schema and numbering" do
    a = @writer.add("home-me-x", title: "First thing", description: "do it")
    b = @writer.add("home-me-x", title: "Follow", parent: a["n"])
    data = JSON.parse(File.read(File.join(@dir, "home-me-x.json")))
    assert_equal [1, 2], data["items"].map { |i| i["n"] }
    assert_nil data["items"][1]["awaitingApproval"], "follow-ups are never gated on approval"
    assert_equal %w[n title description status questions log createdAt updatedAt], data["items"][0].keys
    assert_equal 2, b["n"]
  end

  test "ask blocks, answering the last question resumes running" do
    @writer.add("home-me-x", title: "T")
    @writer.set_status("home-me-x", 1, "running")
    @writer.ask("home-me-x", 1, [{ q: "Which?", options: %w[a b c d e] }])
    item = @store.find("home-me-x:1")
    assert_equal "waiting", item.display_status
    assert_equal 4, item.questions.first.options.size

    @writer.answer("home-me-x", 1, 0, "b")
    item = @store.find("home-me-x:1")
    assert_equal "running", item.status
    assert_equal "b", item.questions.first.a
    assert(item.log.any? { |l| l["text"].include?("Answered from myjira") })
  end

  test "merge_into folds items" do
    3.times { |i| @writer.add("home-me-x", title: "T#{i}") }
    @writer.merge_into("home-me-x", 1, [2, 3])
    items = @store.items_for("home-me-x").index_by(&:n)
    assert_equal "merged", items[2].status
    assert_includes items[1].description, "Folded in #3"
  end

  test "writer rejects bad slugs" do
    assert_raises(ArgumentError) { @writer.add("../etc", title: "x") }
  end

  test "router uses validated structured output, else the table" do
    item = Struct.new(:title, :description, :key).new("t", "d", "k:1")
    good = WorkQueue::Router.new(runner: ->(_) { [{ structured_output: { model: "claude-haiku-5-5", effort: "low", reason: "tiny" } }.to_json, true] })
    c = good.choose(item, "implement")
    assert_equal %w[claude-haiku-5-5 low router], [c.model, c.effort, c.source]

    bad = WorkQueue::Router.new(runner: ->(_) { [{ structured_output: { model: "gpt-9", effort: "low", reason: "x" } }.to_json, true] })
    c = bad.choose(item, "plan")
    assert_equal %w[claude-sonnet-5-5 high table], [c.model, c.effort, c.source]
  end

  test "router honours lock and escalates after failures" do
    item = Struct.new(:title, :description, :key).new("t", "d", "k:1")
    router = WorkQueue::Router.new(runner: ->(_) { ["", false] })
    locked = router.choose(item, "plan", run: { "lock_model" => "1", "override_model" => "claude-fable-5-2", "override_effort" => "max" })
    assert_equal "claude-fable-5-2", locked.model

    esc = router.choose(item, "implement", attempts: 1)
    assert_equal %w[claude-opus-5-5 medium], [esc.model, esc.effort]
  end

  test "escalation is one step per failure: model first, then effort, never max" do
    item = Struct.new(:title, :description, :key).new("t", "d", "k:1")
    router = WorkQueue::Router.new(runner: ->(_) { ["", false] })
    steps = (0..4).map { |n| router.choose(item, "plan", attempts: n).then { |c| [c.model, c.effort] } }
    assert_equal [%w[claude-sonnet-5-5 high], %w[claude-opus-5-5 high], %w[claude-opus-5-5 xhigh],
                  %w[claude-opus-5-5 xhigh], %w[claude-opus-5-5 xhigh]], steps
    assert_equal steps.first(3), WorkQueue::Router.ladder("claude-sonnet-5-5", "high")
    assert_equal %w[claude-fable-5-2 xhigh], WorkQueue::Router.climb("claude-fable-5-2", "high", 3), "off-ladder models only gain effort"
    assert_equal %w[claude-opus-5-5 max], WorkQueue::Router.climb("claude-opus-5-5", "max", 1), "a max you chose is kept, not lowered"
  end

  test "the routing table caps the router on a first attempt, and a saved table wins over the defaults" do
    item = Struct.new(:title, :description, :key).new("t", "d", "k:1")
    eager = WorkQueue::Router.new(runner: ->(_) { [{ structured_output: { model: "claude-opus-5-5", effort: "max", reason: "big" } }.to_json, true] })
    c = eager.choose(item, "plan")
    assert_equal %w[claude-sonnet-5-5 xhigh router], [c.model, c.effort, c.source]
    assert_includes c.reason, "capped"

    WorkQueue::RunState.save_routing("plan" => { "model" => "claude-opus-5-5", "effort" => "max" })
    c = eager.choose(item, "plan")
    assert_equal %w[claude-opus-5-5 max], [c.model, c.effort], "your saved table is the ceiling"
    cheap = WorkQueue::Router.new(runner: ->(_) { [{ structured_output: { model: "claude-haiku-5-5", effort: "low", reason: "tiny" } }.to_json, true] })
    assert_equal "claude-haiku-5-5", cheap.choose(item, "plan").model, "the router may still go cheaper"
  end

  test "a project over its daily budget holds new starts until forced or under budget" do
    @writer.add("home-me-x", title: "T")
    key = "home-me-x:1"
    sup = WorkQueue::Supervisor.new(store: @store, writer: @writer)
    waiting = "#{WorkQueue::RunState::PREFIX}:waiting"
    WorkQueue::RunState.save_project("home-me-x", "daily_budget" => 1.0)
    WorkQueue::Costs.add(key, 1.25, phase: "plan", model: "claude-sonnet-5-5")
    assert WorkQueue::RunState.over_budget?("home-me-x")

    sup.handle({ "action" => "start", "key" => key })
    assert_empty WorkQueue::RunState.redis.lrange(waiting, 0, -1)
    assert_equal [key], WorkQueue::RunState.held("home-me-x")
    item = @store.find(key)
    assert_equal "queued", item.status
    assert(item.log.any? { |l| l["text"].match?(/Daily budget reached \(\$1\.25 of \$1\.00 today\)/) })

    sup.handle({ "action" => "start", "key" => key, "force" => true })
    assert_equal [key], WorkQueue::RunState.redis.lrange(waiting, 0, -1)
    assert_empty WorkQueue::RunState.held("home-me-x")

    WorkQueue::RunState.redis.del(waiting)
    sup.handle({ "action" => "start", "key" => key })
    WorkQueue::RunState.save_project("home-me-x", "daily_budget" => 5.0)
    sup.send(:release_held)
    assert_equal [key], WorkQueue::RunState.redis.lrange(waiting, 0, -1), "released once the project is under budget"
    assert_empty WorkQueue::RunState.held("home-me-x")
  end

  test "session runner builds real claude flags and parses the stream" do
    @writer.add("home-me-x", title: "T")
    item = @store.find("home-me-x:1")
    choice = WorkQueue::Router::Choice.new(model: "claude-sonnet-5-5", effort: "medium", reason: "r")
    r = WorkQueue::SessionRunner.new(item, key: item.key, phase: "implement", choice: choice, cwd: @dir,
                                           resume: "sess-1", allowed: ["Bash(bin/rails test:*)"])
    cmd = r.command
    assert_equal %w[claude -p], cmd.first(2)
    %w[--model claude-sonnet-5-5 --effort medium --permission-mode acceptEdits --resume sess-1 --allowedTools].each { |f| assert_includes cmd, f }
    assert_includes cmd, "Bash(git push:*)"
    assert_includes cmd, "Bash(ls:*)"
    assert_includes cmd, "Write(//tmp/**)"
    assert_includes cmd, "Bash(bin/rails test:*)"
    assert_equal "Bash(git push origin main:*)", cmd[cmd.index("--disallowedTools") + 1]

    result = WorkQueue::SessionRunner::Result.new(denials: [])
    r.handle({ type: "system", subtype: "init", session_id: "S" }.to_json, result)
    r.handle({ type: "result", session_id: "S", result: "done https://github.com/o/r/pull/9", total_cost_usd: 0.5,
               permission_denials: [{ tool_name: "Bash", tool_input: { command: "rm -rf x" } }] }.to_json, result)
    assert_equal "S", result.session_id
    assert_in_delta 0.5, result.cost
    assert_equal 1, result.denials.size
    assert_equal "https://github.com/o/r/pull/9", WorkQueue::SessionRunner.pr_in(result.text)
  end

  test "questions block is parsed" do
    text = "Need input\n```wq-questions\n[{\"q\":\"Pick\",\"options\":[\"A\",\"B\"]}]\n```"
    assert_equal [{ q: "Pick", options: %w[A B] }], WorkQueue::SessionRunner.questions_in(text)
    assert_empty WorkQueue::SessionRunner.questions_in("```wq-questions\nnot json```")
  end

  test "permission answers map to allowed tools" do
    sup = WorkQueue::Supervisor.new(store: @store, writer: @writer)
    key = "home-me-x:1"
    WorkQueue::RunState.set(key, { "pending_permissions" => [{ tool_name: "Bash", tool_input: { command: "npm run build" } }].to_json })
    prompt = sup.send(:answer_prompt, key, { "text" => "Always allow in this project" })
    assert_includes prompt, "Bash(npm run build:*)"
    assert_equal ["Bash(npm run build:*)"], WorkQueue::RunState.project("home-me-x")["always_allow"]
    assert_equal "Answer to your question: blue", sup.send(:answer_prompt, key, { "text" => "blue" })
  end

  test "several permission answers resume the session once" do
    sup = WorkQueue::Supervisor.new(store: @store, writer: @writer)
    key = "home-me-x:2"
    denials = [{ tool_name: "Bash", tool_input: { command: "git push" } }, { tool_name: "WebFetch", tool_input: { url: "https://x.test" } }]
    WorkQueue::RunState.set(key, { "pending_permissions" => denials.to_json })
    assert_nil sup.send(:answer_prompt, key, { "text" => "Allow once", "q" => "Permission: WebFetch https://x.test?" })
    prompt = sup.send(:answer_prompt, key, { "text" => "Deny", "q" => "Permission: Bash git push?" })
    assert_includes prompt, "Permission granted for WebFetch."
    assert_includes prompt, "denied Bash(git push:*)"
    assert_equal ["WebFetch"], JSON.parse(WorkQueue::RunState.get(key)["allow_once"])
  end

  test "permission rules use the subcommand and validate" do
    assert_equal "Bash(bundle exec rspec:*)", WorkQueue::PermissionRules.for_command("cd /a && RAILS_ENV=test bundle exec rspec x")
    assert_equal "Bash(ls:*)", WorkQueue::PermissionRules.for_command("ls -la")
    assert_equal ["Bash(git push:*)", "WebFetch"], WorkQueue::PermissionRules.clean(["Bash(git push:*)", "WebFetch", "x y", ""])
  end

  test "suggestions are validated, cached and broadcast" do
    item = WorkQueue::Store::Item.new(slug: "home-me-x", n: 3, title: "T", description: "d")
    out = { structured_output: { answers: ["Yes", " Yes ", "No", ""] } }.to_json
    answers = WorkQueue::Suggestions.generate(item, 0, "Ship it?", runner: ->(_) { [out, true] })
    assert_equal %w[Yes No], answers
    assert_equal %w[Yes No], WorkQueue::Suggestions.get("Ship it?")
    assert_nil WorkQueue::Suggestions.validate(["only one"])
  end
end
