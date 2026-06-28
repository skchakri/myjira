require "test_helper"

# The cost-reconcile leg of /conversations/sync and the daemon-facing budget
# endpoints on session_launches.
class CostSyncTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "CS", slug: "cs-#{SecureRandom.hex(3)}", repo_path: "/tmp/cs")
    @convo = @project.conversations.create!(session_id: SecureRandom.uuid, model: "opus")
    @launch = @project.session_launches.create!(prompt: "/board-engineer", status: "launched",
                                                session_id: SecureRandom.uuid, repo_path: "/tmp/cs",
                                                conversation: @convo, pipeline_step: "engineering")
  end

  def sync!(usage:)
    post "/api/v1/conversations/sync", params: {
      project: { slug: @project.slug, repo_path: @project.repo_path },
      conversation: { session_id: @convo.session_id, model: "opus" },
      messages: [{ ext_id: SecureRandom.uuid, role: "assistant", kind: "message",
                   body: "working", payload: { usage: usage } }]
    }, as: :json
    assert_response :success
  end

  test "sync folds usage + $ estimate onto the bound launch" do
    sync!(usage: { input_tokens: 1_000_000, output_tokens: 1_000_000 })
    @launch.reload
    assert_equal 1_000_000, @launch.token_input
    assert_equal 1_000_000, @launch.token_output
    assert_equal 9000, @launch.estimated_cost_cents # opus 1M in + 1M out
  end

  test "re-sync recomputes (not accumulates)" do
    sync!(usage: { input_tokens: 1_000_000, output_tokens: 0 })
    # A second sync turn that re-sends the SAME first message must not double it.
    post "/api/v1/conversations/sync", params: {
      project: { slug: @project.slug, repo_path: @project.repo_path },
      conversation: { session_id: @convo.session_id, model: "opus" },
      messages: [{ ext_id: SecureRandom.uuid, role: "assistant", kind: "message",
                   body: "more", payload: { usage: { input_tokens: 1_000_000, output_tokens: 0 } } }]
    }, as: :json
    @launch.reload
    # Two distinct messages, 1M each → 2M total, recomputed from the full set.
    assert_equal 2_000_000, @launch.token_input
  end

  test "no usage leaves the launch cost nil (renders n/a)" do
    sync!(usage: nil)
    @launch.reload
    assert_nil @launch.token_input
    assert_nil @launch.estimated_cost_cents
  end

  # --- daemon endpoints ---

  test "update accepts exit_code" do
    patch "/api/v1/session_launches/#{@launch.id}", params: { status: "canceled", exit_code: 137 }, as: :json
    assert_response :success
    @launch.reload
    assert_equal "canceled", @launch.status
    assert_equal 137, @launch.exit_code
  end

  test "to_cancel lists only canceling launches with their tmux target" do
    @launch.update!(status: "canceling", tmux_target: "myjira:cs-1", over_budget: true, over_budget_at: Time.current)
    get "/api/v1/session_launches/to_cancel"
    assert_response :success
    rows = JSON.parse(response.body)
    assert_equal 1, rows.size
    assert_equal @launch.id, rows.first["id"]
    assert_equal "myjira:cs-1", rows.first["tmux_target"]
  end

  test "to_cancel ignores ordinary in-flight launches" do
    get "/api/v1/session_launches/to_cancel"
    assert_response :success
    assert_empty JSON.parse(response.body)
  end
end
