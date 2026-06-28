require "test_helper"

# Approve-&-merge + PR reconciliation: the web "✓ merge" flag, the daemon's
# GET pr_sync work list, and POST pr_sync applying gh outcomes to the board.
class BoardPrSyncTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "PR Sync", slug: "pr-sync-#{SecureRandom.hex(3)}",
                               repo_path: "/tmp/pr-sync")
  end

  def in_review_item(**attrs)
    @project.tasks.create!({ title: "Reviewable", board_state: "in_review",
                             pr_url: "https://github.com/x/y/pull/1", pr_number: 1,
                             pr_state: "open" }.merge(attrs))
  end

  # --- web "Approve & merge" ------------------------------------------------
  test "request_merge flags an in_review item with a PR" do
    item = in_review_item
    post board_item_merge_path(@project, item)
    assert_redirected_to board_path(@project)
    assert item.reload.merge_requested?, "merge_requested_at is stamped"
    assert_equal "in_review", item.board_state, "stays in review until the daemon merges"
  end

  test "request_merge is refused when the item is not in review" do
    item = @project.tasks.create!(title: "Planned", board_state: "planned")
    post board_item_merge_path(@project, item)
    assert_not item.reload.merge_requested?
    assert_match(/in review/i, flash[:alert])
  end

  # --- daemon work list (GET) ----------------------------------------------
  test "pr_sync lists approved merges and pollable in_review PRs" do
    approved = in_review_item(merge_requested_at: Time.current)
    pollable = in_review_item(pr_synced_at: nil)
    fresh    = in_review_item(pr_synced_at: Time.current) # just opened → throttled

    get "/api/v1/board/pr_sync"
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [approved.id], body["to_merge"].map { |h| h["task_id"] }
    poll_ids = body["to_poll"].map { |h| h["task_id"] }
    assert_includes poll_ids, pollable.id
    assert_not_includes poll_ids, fresh.id, "freshly-synced PRs are throttled out"
    assert_not_includes poll_ids, approved.id, "approved-to-merge items aren't double-listed"
  end

  # --- applying daemon outcomes (POST) -------------------------------------
  test "a successful merge moves the item to done and marks the PR merged" do
    item = in_review_item(merge_requested_at: Time.current)
    post "/api/v1/board/pr_sync", params: { results: [{ task_id: item.id, action: "merge", ok: true }] }, as: :json
    assert_response :success
    item.reload
    assert_equal "done", item.board_state
    assert_equal "merged", item.pr_state
    assert_not item.merge_requested?
    assert item.finished_at.present?
  end

  test "a failed merge keeps the item in review with a note" do
    item = in_review_item(merge_requested_at: Time.current)
    post "/api/v1/board/pr_sync",
         params: { results: [{ task_id: item.id, action: "merge", ok: false, error: "required checks failing" }] }, as: :json
    item.reload
    assert_equal "in_review", item.board_state
    assert_not item.merge_requested?, "the request is cleared so it doesn't retry forever"
    assert_match(/required checks failing/, item.agent_notes)
  end

  test "polling sees a PR merged on GitHub and marks it done" do
    item = in_review_item
    post "/api/v1/board/pr_sync", params: { results: [{ task_id: item.id, action: "poll", state: "merged" }] }, as: :json
    assert_equal "done", item.reload.board_state
    assert_equal "merged", item.pr_state
  end

  test "polling sees a closed-unmerged PR and fails the item" do
    item = in_review_item
    post "/api/v1/board/pr_sync", params: { results: [{ task_id: item.id, action: "poll", state: "closed" }] }, as: :json
    item.reload
    assert_equal "failed", item.board_state
    assert_equal "closed", item.pr_state
    assert_match(/closed/i, item.agent_notes)
  end

  test "polling an still-open PR just stamps the sync time" do
    item = in_review_item(pr_synced_at: nil)
    post "/api/v1/board/pr_sync", params: { results: [{ task_id: item.id, action: "poll", state: "open" }] }, as: :json
    item.reload
    assert_equal "in_review", item.board_state
    assert item.pr_synced_at.present?, "stamped so it's throttled out of the next poll"
  end

  # --- conflict detection + the web "Resolve & merge" button ----------------
  test "polling an open PR persists gh's mergeable verdict so the board can flag conflicts" do
    item = in_review_item(pr_synced_at: nil)
    post "/api/v1/board/pr_sync",
         params: { results: [{ task_id: item.id, action: "poll", state: "open", mergeable: "CONFLICTING" }] }, as: :json
    assert_equal "CONFLICTING", item.reload.pr_mergeable
    assert item.conflicting?, "a conflicting in_review PR surfaces the Resolve control"
  end

  test "resolve_conflicts queues a resolution and stamps the in-flight guard on a conflicting item" do
    item = in_review_item(pr_mergeable: "CONFLICTING")
    post board_item_resolve_conflicts_path(@project, item)
    assert_redirected_to board_path(@project)
    item.reload
    assert item.resolving_conflicts?, "conflict_resolution_at is stamped"
    assert_equal "in_review", item.board_state, "stays in review until the agent merges"
  end

  test "resolve_conflicts is refused when the PR has no conflict" do
    item = in_review_item(pr_mergeable: "MERGEABLE")
    post board_item_resolve_conflicts_path(@project, item)
    assert_nil item.reload.conflict_resolution_at
    assert_match(/conflicting/i, flash[:alert])
  end
end
