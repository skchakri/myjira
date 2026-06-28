require "test_helper"

# Verifies that the /api/v1/conversations/sync endpoint persists token counts
# and recomputes cost_usd via ModelPricing.
class ConversationTokenCostTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "TokCost", slug: "tokcost-#{SecureRandom.hex(3)}",
                               repo_path: "/tmp/tokcost")
  end

  test "sync stores token counts and computes opus cost" do
    session_id = SecureRandom.uuid
    post sync_api_v1_conversations_path,
         params: {
           project: { slug: @project.slug, name: @project.name, repo_path: @project.repo_path },
           conversation: {
             session_id: session_id,
             source: "claude-cli",
             model: "claude-opus-4-5",
             input_tokens: 1000,
             output_tokens: 500,
             cache_tokens: 200
           },
           messages: []
         },
         as: :json

    assert_response :ok
    convo = Conversation.find_by!(session_id: session_id)
    assert_equal 1000, convo.input_tokens
    assert_equal 500,  convo.output_tokens
    assert_equal 200,  convo.cache_tokens

    expected = ModelPricing.cost_for(model: "claude-opus-4-5", input: 1000, output: 500, cache: 200)
    assert_equal expected, convo.cost_usd
  end

  test "sync without token keys leaves prior token values intact" do
    session_id = SecureRandom.uuid
    # Seed a conversation with known counts via a first sync
    @project.conversations.create!(
      session_id: session_id,
      source: "claude-cli",
      started_at: Time.current,
      last_message_at: Time.current,
      input_tokens: 500,
      output_tokens: 100,
      cache_tokens: 50,
      cost_usd: BigDecimal("0.01")
    )

    # Second sync without token keys — must not zero the values
    post sync_api_v1_conversations_path,
         params: {
           project: { slug: @project.slug, name: @project.name, repo_path: @project.repo_path },
           conversation: { session_id: session_id, source: "claude-cli" },
           messages: []
         },
         as: :json

    assert_response :ok
    convo = Conversation.find_by!(session_id: session_id)
    assert_equal 500, convo.input_tokens,  "input_tokens must not be zeroed by a keyless sync"
    assert_equal 100, convo.output_tokens, "output_tokens must not be zeroed"
    assert_equal 50,  convo.cache_tokens,  "cache_tokens must not be zeroed"
  end

  test "sync with opus model computes correct cost" do
    session_id = SecureRandom.uuid
    post sync_api_v1_conversations_path,
         params: {
           project: { slug: @project.slug, name: @project.name, repo_path: @project.repo_path },
           conversation: {
             session_id: session_id,
             source: "claude-cli",
             model: "claude-opus-4-8",
             input_tokens: 0,
             output_tokens: 1_000_000,
             cache_tokens: 0
           },
           messages: []
         },
         as: :json

    convo = Conversation.find_by!(session_id: session_id)
    # opus output: 75 USD per 1M tokens
    assert_equal BigDecimal("75.0"), convo.cost_usd
  end
end
