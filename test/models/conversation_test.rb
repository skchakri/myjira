require "test_helper"

class ConversationTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Test", slug: "test-conv-#{SecureRandom.hex(3)}",
                               repo_path: "/tmp/test-conv")
  end

  def new_conversation(**attrs)
    Conversation.create!({ session_id: SecureRandom.uuid, project: @project }.merge(attrs))
  end

  def add_message(convo, body:, role: "assistant", kind: "message")
    convo.conversation_messages.create!(
      ext_id: SecureRandom.uuid,
      role: role,
      kind: kind,
      body: body,
      position: (convo.conversation_messages.maximum(:position) || -1) + 1,
      occurred_at: Time.current
    )
  end

  # --- MODEL_DEPRECATION_RE matcher ---

  test "MODEL_DEPRECATION_RE matches 'model is deprecated'" do
    assert_match Conversation::MODEL_DEPRECATION_RE, "Warning: model claude-3-opus is deprecated and will be removed."
  end

  test "MODEL_DEPRECATION_RE matches 'deprecated model'" do
    assert_match Conversation::MODEL_DEPRECATION_RE, "The deprecated model you selected is no longer available."
  end

  test "MODEL_DEPRECATION_RE matches 'out of policy'" do
    assert_match Conversation::MODEL_DEPRECATION_RE, "This model choice is out of policy for your account."
  end

  test "MODEL_DEPRECATION_RE is case-insensitive" do
    assert_match Conversation::MODEL_DEPRECATION_RE, "MODEL IS DEPRECATED"
  end

  test "MODEL_DEPRECATION_RE does not match normal conversation text" do
    refute_match Conversation::MODEL_DEPRECATION_RE, "Here is the code you requested."
    refute_match Conversation::MODEL_DEPRECATION_RE, "Let me help you fix that bug."
  end

  # --- compute_model_deprecated ---

  test "compute_model_deprecated returns false when there are no messages" do
    convo = new_conversation
    refute convo.send(:compute_model_deprecated)
  end

  test "compute_model_deprecated returns false when no message body matches the regex" do
    convo = new_conversation
    add_message(convo, body: "This is a normal assistant reply about your code.")
    add_message(convo, role: "user", body: "Please fix the test.")
    refute convo.send(:compute_model_deprecated)
  end

  test "compute_model_deprecated returns true when a message body contains 'model is deprecated'" do
    convo = new_conversation
    add_message(convo, role: "user",
                body: "Warning: model claude-3-opus-20240229 is deprecated and will be removed.")
    assert convo.send(:compute_model_deprecated)
  end

  test "compute_model_deprecated returns true when a message body contains 'out of policy'" do
    convo = new_conversation
    add_message(convo, body: "This model is out of policy. Please switch to a supported model.")
    assert convo.send(:compute_model_deprecated)
  end

  test "compute_model_deprecated ignores tool messages" do
    convo = new_conversation
    # A tool message whose body happens to contain 'deprecated model' text should not count
    convo.conversation_messages.create!(
      ext_id: SecureRandom.uuid, role: "assistant", kind: "tool",
      body: "model deprecated output in a bash call",
      position: 0, occurred_at: Time.current
    )
    refute convo.send(:compute_model_deprecated), "tool-kind messages should not trigger the flag"
  end

  # --- refresh_counts! sets model_deprecated ---

  test "refresh_counts! sets model_deprecated true when a message matches the deprecation pattern" do
    convo = new_conversation
    add_message(convo, body: "The model claude-instant-1.2 is deprecated.")
    convo.refresh_counts!
    assert convo.reload.model_deprecated
  end

  test "refresh_counts! leaves model_deprecated false when no message matches" do
    convo = new_conversation
    add_message(convo, body: "Everything is running fine.")
    convo.refresh_counts!
    refute convo.reload.model_deprecated
  end

  test "refresh_counts! preserves model_deprecated true when already flagged (e.g. via warnings field)" do
    # Once flagged (e.g. via the sync warnings: field), the flag is sticky — a new
    # sync batch without a matching message body must not silently clear it.
    convo = new_conversation(model_deprecated: true)
    add_message(convo, body: "Normal message with no warning.")
    convo.refresh_counts!
    assert convo.reload.model_deprecated,
      "model_deprecated should remain true once set, even if new messages don't match"
  end
end
