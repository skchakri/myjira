require "test_helper"
require "turbo/broadcastable/test_helper"

class TaskTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

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

  test "updating plan, agent_notes or board_state broadcasts a live activity refresh" do
    item = @project.tasks.create!(title: "Live", item_type: "feature")
    assert_turbo_stream_broadcasts [item, :activity], count: 1 do
      item.update!(plan: "## Goal\nDo the thing")
    end
    assert_turbo_stream_broadcasts [item, :activity], count: 1 do
      item.update!(agent_notes: "Branching off main; assuming X.")
    end
    assert_turbo_stream_broadcasts [item, :activity], count: 1 do
      item.update!(board_state: "in_progress")
    end
  end

  test "an unrelated save does not broadcast an activity refresh" do
    item = @project.tasks.create!(title: "Quiet", item_type: "feature")
    assert_no_turbo_stream_broadcasts [item, :activity] do
      item.update!(position: 42)
    end
  end

  # board_ordered: default sort is newest-created first; manual position wins
  test "board_ordered returns newest-created items first when no positions are set" do
    # Create items with explicit created_at to avoid sub-second flakiness
    older = @project.tasks.create!(title: "Older", item_type: "task", board_state: "pending",
                                   created_at: 2.hours.ago)
    newer = @project.tasks.create!(title: "Newer", item_type: "task", board_state: "pending",
                                   created_at: 1.hour.ago)
    newest = @project.tasks.create!(title: "Newest", item_type: "task", board_state: "pending",
                                    created_at: 1.minute.ago)

    # All three have no position (NULL) — newest should come first
    ids = @project.tasks.board_ordered.map(&:id)
    assert_equal [newest.id, newer.id, older.id], ids,
                 "unpositioned items must sort newest-first (created_at DESC)"
  end

  test "board_ordered: a manually set position sorts ahead of unpositioned items" do
    # item with position=1 must come before items with NULL position regardless of created_at
    unpositioned_new = @project.tasks.create!(title: "Unpositioned New", item_type: "task",
                                              board_state: "pending", created_at: 1.minute.ago)
    pinned = @project.tasks.create!(title: "Pinned", item_type: "task",
                                    board_state: "pending", created_at: 1.hour.ago)
    pinned.update_column(:position, 1)

    ids = @project.tasks.board_ordered.map(&:id)
    assert_equal pinned.id, ids.first, "positioned item (position=1) must be first"
    assert_equal unpositioned_new.id, ids.last, "unpositioned new item comes after positioned ones"
  end

  test "board_ordered: two positioned items respect their numeric position order" do
    first_pos = @project.tasks.create!(title: "First", item_type: "task", board_state: "pending")
    second_pos = @project.tasks.create!(title: "Second", item_type: "task", board_state: "pending")
    first_pos.update_column(:position, 1)
    second_pos.update_column(:position, 2)

    ids = @project.tasks.board_ordered.map(&:id)
    assert_equal first_pos.id, ids.first
    assert_equal second_pos.id, ids.second
  end
end
