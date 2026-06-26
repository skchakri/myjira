require "test_helper"

class TaskTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "T", slug: "t-#{SecureRandom.hex(3)}", repo_path: "/tmp/t")
  end

  def in_review_item(**attrs)
    @project.tasks.create!({ title: "Item", item_type: "task", board_state: "in_review",
                             pr_url: "https://github.com/x/y/pull/3", pr_number: 3, pr_state: "open" }.merge(attrs))
  end

  test "reject_pr! moves an in_review item to failed, clears the merge flag, leaves the PR untouched" do
    item = in_review_item(merge_requested_at: Time.current)
    assert item.reject_pr!
    item.reload
    assert_equal "failed", item.board_state
    assert_nil item.merge_requested_at, "the merge request flag is cleared"
    assert_equal "https://github.com/x/y/pull/3", item.pr_url, "PR is left open on GitHub"
    assert_equal "open", item.pr_state
  end

  test "reject_pr! does not increment autopilot_attempts" do
    item = in_review_item(autopilot_attempts: 0)
    item.reject_pr!
    assert_equal 0, item.reload.autopilot_attempts
  end

  test "a rejected item drops out of the daemon merge and poll scopes" do
    item = in_review_item(merge_requested_at: Time.current)
    item.reject_pr!
    assert_not_includes Task.awaiting_merge, item, "no longer queued for gh pr merge"
    assert_not_includes Task.pr_pollable(Time.current), item, "no longer polled for an external merge/close"
  end

  test "reject_pr! with a reason logs a comment and stamps agent_notes" do
    item = in_review_item
    assert_difference -> { item.comments.count }, 1 do
      item.reject_pr!(note: "needs design review")
    end
    assert_equal "Rejected: needs design review", item.comments.last.body
    assert_equal "Rejected: needs design review", item.reload.agent_notes
  end

  test "reject_pr! is a no-op unless in_review with a PR" do
    planned = @project.tasks.create!(title: "P", item_type: "task", board_state: "planned")
    refute planned.reject_pr!
    assert_equal "planned", planned.reload.board_state

    no_pr = @project.tasks.create!(title: "N", item_type: "task", board_state: "in_review")
    refute no_pr.reject_pr!
    assert_equal "in_review", no_pr.reload.board_state
  end
end
