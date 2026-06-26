require "test_helper"

# The Searchable concern (Postgres FTS) on each of the four searchable models.
# The stored `tsvector` is computed by PG on insert, so `full_text` matches the
# instant a record is created — no reindex step. Rare, distinct nonsense words
# keep each model's match from leaking into another's assertions.
class SearchableTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Search", slug: "search-#{SecureRandom.hex(3)}",
                               repo_path: "/tmp/search")
  end

  test "Task.full_text matches title and description, excludes non-matches" do
    hit  = @project.tasks.create!(title: "Penguin migration", description: "cold storage")
    miss = @project.tasks.create!(title: "Zebra dashboard")

    ids = Task.full_text("penguin").pluck(:id)
    assert_includes ids, hit.id
    refute_includes ids, miss.id
    assert_includes Task.full_text("storage").pluck(:id), hit.id
  end

  test "Task.full_text searches implementation_notes, plan and agent_notes" do
    t = @project.tasks.create!(title: "Plain title", implementation_notes: "uses quokka indexing",
                               plan: "step one: aardwolf", agent_notes: "blocked on numbat")
    assert_includes Task.full_text("quokka").pluck(:id), t.id
    assert_includes Task.full_text("aardwolf").pluck(:id), t.id
    assert_includes Task.full_text("numbat").pluck(:id), t.id
  end

  test "FollowUpTask.full_text matches title and description" do
    fu = @project.follow_up_tasks.create!(title: "Wombat login bug", description: "throws on capybara")
    assert_includes FollowUpTask.full_text("wombat").pluck(:id), fu.id
    assert_includes FollowUpTask.full_text("capybara").pluck(:id), fu.id
    assert_empty FollowUpTask.full_text("ocelot").to_a
  end

  test "ConversationMessage.full_text matches body and captured tool payload" do
    convo = @project.conversations.create!(session_id: "sess-#{SecureRandom.hex(4)}")
    msg = convo.conversation_messages.create!(ext_id: "e1", role: "assistant", body: "ran the marmoset suite")
    tool = convo.conversation_messages.create!(ext_id: "e2", role: "assistant", kind: "tool",
                                               payload: { "tool" => "Bash", "input" => { "command" => "rails dingo:task" } })

    assert_includes ConversationMessage.full_text("marmoset").pluck(:id), msg.id
    assert_includes ConversationMessage.full_text("dingo").pluck(:id), tool.id, "indexes the tool payload text"
  end

  test "TestResult.full_text matches notes and actual_result" do
    plan = @project.test_plans.create!(title: "Plan")
    tc   = plan.test_cases.create!(title: "Case")
    run  = plan.test_runs.create!            # seeds one pending result for the case
    res  = run.test_results.first
    res.update!(notes: "axolotl assertion failed", actual_result: "got pangolin")

    assert_includes TestResult.full_text("axolotl").pluck(:id), res.id
    assert_includes TestResult.full_text("pangolin").pluck(:id), res.id
  end

  test "full_text returns nothing for a blank query and runs no SQL error" do
    @project.tasks.create!(title: "anything")
    assert_empty Task.full_text("").to_a
    assert_empty Task.full_text("   ").to_a
  end

  test "full_text supports websearch-style phrase and exclusion operators" do
    a = @project.tasks.create!(title: "alpha beta gamma")
    b = @project.tasks.create!(title: "alpha delta")

    phrase = Task.full_text('"alpha beta"').pluck(:id)
    assert_includes phrase, a.id
    refute_includes phrase, b.id

    excluded = Task.full_text("alpha -beta").pluck(:id)
    assert_includes excluded, b.id
    refute_includes excluded, a.id
  end
end
