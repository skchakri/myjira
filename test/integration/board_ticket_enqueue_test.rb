require "test_helper"

# Verifies the conversation sync endpoint enqueues BoardTicketFromSessionJob only
# when an enrichment pass is actually due: a substantive ask present, the throttle
# window clear, and the global kill switch on.
class BoardTicketEnqueueTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @project = Project.create!(name: "EnqTest", slug: "enq-#{SecureRandom.hex(3)}",
                               repo_path: "/tmp/enq-#{SecureRandom.hex(3)}")
    @session = SecureRandom.uuid
    Setting.auto_board_tickets = true
  end

  def sync(messages, session: @session)
    post sync_api_v1_conversations_path,
      params: {
        project: { slug: @project.slug, name: @project.name, repo_path: @project.repo_path },
        conversation: { session_id: session, cwd: "/tmp", source: "claude-cli" },
        messages: messages
      },
      as: :json
    assert_response :success
  end

  def user_msg(body)
    { ext_id: SecureRandom.uuid, role: "user", kind: "message", body: body }
  end

  test "enqueues the enrichment job when a substantive user ask lands" do
    assert_enqueued_with(job: BoardTicketFromSessionJob) do
      sync([user_msg("Build me a settings page")])
    end
  end

  test "does not enqueue for a session with no substantive user message" do
    assert_no_enqueued_jobs only: BoardTicketFromSessionJob do
      sync([{ ext_id: SecureRandom.uuid, role: "assistant", kind: "message", body: "Hi there" }])
    end
  end

  test "does not re-enqueue within the throttle window for the same content" do
    sync([user_msg("First ask")])
    convo = Conversation.find_by(session_id: @session)
    # Simulate a completed enrichment pass that consumed the one ask.
    convo.mark_board_enriched!(convo.substantive_user_message_count)

    assert_no_enqueued_jobs only: BoardTicketFromSessionJob do
      sync([{ ext_id: SecureRandom.uuid, role: "assistant", kind: "message", body: "done" }])
    end
  end

  test "does not enqueue when the global kill switch is off" do
    Setting.auto_board_tickets = false
    assert_no_enqueued_jobs only: BoardTicketFromSessionJob do
      sync([user_msg("Build me a settings page")])
    end
  end
end
