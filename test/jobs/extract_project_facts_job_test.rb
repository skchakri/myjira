require "test_helper"

# Mines a settled CLI conversation for durable codebase facts via the `claude`
# CLI and upserts them into KnowledgeFact. We stub the Open3 boundary
# (#run_claude) so the test never shells out; it returns a fixed claude JSON
# envelope whose `result` is the model's reply.
class ExtractProjectFactsJobTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "EF", slug: "ef-#{SecureRandom.hex(3)}", repo_path: "/tmp/ef")
    @convo = Conversation.create!(session_id: SecureRandom.uuid, project: @project)
    6.times { |i| add_message("message #{i}") }
    @convo.refresh_counts!
  end

  def add_message(body, role: "assistant")
    @convo.conversation_messages.create!(
      ext_id: SecureRandom.uuid, role: role, kind: "message", body: body,
      position: (@convo.conversation_messages.maximum(:position) || -1) + 1,
      occurred_at: Time.current
    )
  end

  # Wrap a model reply (the array text) in the claude --output-format json envelope.
  def envelope(result) = { result: result }.to_json

  def run_with(raw)
    job = ExtractProjectFactsJob.new
    job.stub(:run_claude, raw) { job.perform(@convo.id) }
  end

  test "creates deduped facts from a JSON array reply" do
    run_with(envelope(%(["auth lives in app/services/auth", "uuid pks everywhere", "AUTH lives in app/services/auth"])))
    bodies = @project.knowledge_facts.pluck(:body)
    assert_equal 2, bodies.length, "the two auth lines share a fingerprint and must collapse"
    assert_includes bodies, "auth lives in app/services/auth"
    assert_includes bodies, "uuid pks everywhere"
  end

  test "stamps facts_extracted_at so repeated syncs debounce" do
    assert_nil @convo.facts_extracted_at
    run_with(envelope("[]"))
    assert_not_nil @convo.reload.facts_extracted_at
  end

  test "thin transcripts are a no-op" do
    thin = Conversation.create!(session_id: SecureRandom.uuid, project: @project)
    thin.conversation_messages.create!(ext_id: SecureRandom.uuid, role: "user", kind: "message",
                                       body: "hi", position: 0, occurred_at: Time.current)
    thin.refresh_counts!
    job = ExtractProjectFactsJob.new
    job.stub(:run_claude, envelope(%(["should not be stored"]))) { job.perform(thin.id) }
    assert_equal 0, @project.knowledge_facts.count
  end

  test "malformed model output produces no facts and does not raise" do
    assert_nothing_raised do
      run_with(envelope("sorry, I can't help with that"))
    end
    assert_equal 0, @project.knowledge_facts.count
  end

  test "a failing CLI boundary never raises and stamps the debounce marker" do
    job = ExtractProjectFactsJob.new
    boom = ->(*) { raise "claude CLI exited 1" }
    assert_nothing_raised { job.stub(:run_claude, boom) { job.perform(@convo.id) } }
    assert_equal 0, @project.knowledge_facts.count
    assert_not_nil @convo.reload.facts_extracted_at
  end
end
