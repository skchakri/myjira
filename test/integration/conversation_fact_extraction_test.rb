require "test_helper"

# The conversations sync endpoint (hit by the Stop hook after every turn) should
# enqueue project-fact extraction once a session has settled, debounced so the
# repeated idempotent syncs don't spawn `claude` on every turn.
class ConversationFactExtractionTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @project = Project.create!(name: "SyncMem", slug: "sync-mem-#{SecureRandom.hex(3)}",
                               repo_path: "/tmp/sync-mem-#{SecureRandom.hex(3)}", listed: true)
    @session_id = SecureRandom.uuid
  end

  def sync!(messages:, session_id: @session_id)
    post sync_api_v1_conversations_path, params: {
      project: { slug: @project.slug, repo_path: @project.repo_path, name: @project.name },
      conversation: { session_id: session_id },
      messages: messages
    }, as: :json
    assert_response :ok
  end

  def msgs(n, base: "m")
    Array.new(n) do |i|
      { ext_id: "#{base}-#{i}-#{SecureRandom.hex(2)}", role: "assistant", body: "turn #{i}",
        occurred_at: Time.current.iso8601 }
    end
  end

  test "a settled client conversation enqueues fact extraction" do
    assert_enqueued_with(job: ExtractProjectFactsJob) do
      sync!(messages: msgs(4))
    end
  end

  test "a thin conversation does not enqueue extraction" do
    assert_no_enqueued_jobs only: ExtractProjectFactsJob do
      sync!(messages: msgs(2))
    end
  end

  test "a recently-extracted conversation is debounced (no re-enqueue)" do
    sync!(messages: msgs(4))
    convo = Conversation.find_by!(session_id: @session_id)
    convo.update_column(:facts_extracted_at, Time.current)
    assert_no_enqueued_jobs only: ExtractProjectFactsJob do
      sync!(messages: msgs(2, base: "more")) # pushes count higher, still within debounce window
    end
  end

  test "a non-client capture project does not enqueue extraction" do
    capture = Project.create!(name: "Capture", slug: "cap-#{SecureRandom.hex(3)}",
                              repo_path: "/tmp/cap-#{SecureRandom.hex(3)}") # not listed, no work
    assert_no_enqueued_jobs only: ExtractProjectFactsJob do
      post sync_api_v1_conversations_path, params: {
        project: { slug: capture.slug, repo_path: capture.repo_path, name: capture.name },
        conversation: { session_id: SecureRandom.uuid },
        messages: msgs(5)
      }, as: :json
      assert_response :ok
    end
  end
end
