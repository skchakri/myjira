require "test_helper"

# Verifies that model-deprecation warnings are surfaced as a visible badge
# on the conversation index (card) and show page, and that the sync endpoint
# accepts an optional `warnings` field to set the flag immediately.
class ConversationDeprecationTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "DepTest", slug: "dep-test-#{SecureRandom.hex(3)}",
                               repo_path: "/tmp/dep-test")
  end

  def create_conversation(model_deprecated: false)
    Conversation.create!(
      session_id: SecureRandom.uuid,
      project: @project,
      model_deprecated: model_deprecated
    )
  end

  # --- show page ---

  test "show page renders deprecation badge when model_deprecated is true" do
    convo = create_conversation(model_deprecated: true)
    get conversation_path(convo)
    assert_response :success
    assert_match "model deprecated", response.body
  end

  test "show page does not render deprecation badge when model_deprecated is false" do
    convo = create_conversation(model_deprecated: false)
    get conversation_path(convo)
    assert_response :success
    assert_no_match(/model deprecated/, response.body)
  end

  # --- index / card (project-scoped sessions list) ---

  test "conversation card on project sessions page shows badge when model_deprecated" do
    create_conversation(model_deprecated: true)
    get project_conversations_path(@project)
    assert_response :success
    assert_match "model deprecated", response.body
  end

  test "conversation card on project sessions page hides badge when not deprecated" do
    create_conversation(model_deprecated: false)
    get project_conversations_path(@project)
    assert_response :success
    assert_no_match(/model deprecated/, response.body)
  end

  # --- API sync: optional warnings field ---

  test "sync sets model_deprecated when warnings field contains deprecation text" do
    post sync_api_v1_conversations_path,
      params: {
        project: { slug: @project.slug, name: @project.name, repo_path: @project.repo_path },
        conversation: {
          session_id: SecureRandom.uuid,
          cwd: "/tmp",
          source: "claude-cli",
          warnings: "Warning: model claude-3-opus-20240229 is deprecated and will be removed."
        },
        messages: [ { ext_id: SecureRandom.uuid, role: "user", kind: "message", body: "Hello" } ]
      },
      as: :json

    assert_response :success
    convo_id = JSON.parse(response.body)["conversation_id"]
    assert Conversation.find(convo_id).model_deprecated,
      "model_deprecated should be true when warnings contain deprecation text"
  end

  test "sync does not set model_deprecated when warnings field is absent" do
    post sync_api_v1_conversations_path,
      params: {
        project: { slug: @project.slug, name: @project.name, repo_path: @project.repo_path },
        conversation: {
          session_id: SecureRandom.uuid,
          cwd: "/tmp",
          source: "claude-cli"
        },
        messages: [ { ext_id: SecureRandom.uuid, role: "user", kind: "message", body: "Hello" } ]
      },
      as: :json

    assert_response :success
    convo_id = JSON.parse(response.body)["conversation_id"]
    refute Conversation.find(convo_id).model_deprecated
  end

  test "sync sets model_deprecated via refresh_counts! when a message body matches" do
    post sync_api_v1_conversations_path,
      params: {
        project: { slug: @project.slug, name: @project.name, repo_path: @project.repo_path },
        conversation: {
          session_id: SecureRandom.uuid,
          cwd: "/tmp",
          source: "claude-cli"
        },
        messages: [
          { ext_id: SecureRandom.uuid, role: "user", kind: "message",
            body: "model claude-instant is deprecated and has been auto-upgraded" }
        ]
      },
      as: :json

    assert_response :success
    convo_id = JSON.parse(response.body)["conversation_id"]
    assert Conversation.find(convo_id).model_deprecated,
      "model_deprecated should be true after refresh_counts! detects a deprecation body"
  end
end
