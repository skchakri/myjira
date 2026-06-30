require "test_helper"

class Board::ConsolidatorTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "C", slug: "c-#{SecureRandom.hex(3)}", repo_path: "/tmp/c")
  end

  test "merge! folds the group into the oldest as primary and appends content" do
    older = @project.tasks.create!(title: "Add export", item_type: "feature", board_state: "pending",
                                   description: "Original", created_at: 2.hours.ago)
    newer = @project.tasks.create!(title: "CSV export too", item_type: "feature", board_state: "pending",
                                   description: "Also CSV")
    primary = Board::Consolidator.merge!([newer, older])
    assert_equal older.id, primary.id, "oldest is primary"
    newer.reload
    assert_equal older.id, newer.merged_into_id
    assert_match "Merged sub-items", older.reload.description
    assert_match "CSV export too", older.description
  end

  test "run! merges items the detector flags as related" do
    a = @project.tasks.create!(title: "Dark mode", item_type: "feature", board_state: "pending",
                               created_at: 1.hour.ago)
    b = @project.tasks.create!(title: "Night theme", item_type: "feature", board_state: "pending")
    Board::Consolidator.stub(:detect_related, ->(_task, cands) { cands.map(&:id) }) do
      Board::Consolidator.run!(b)
    end
    assert_equal a.id, b.reload.merged_into_id
  end

  test "run! is a no-op when the detector finds nothing related" do
    @project.tasks.create!(title: "Unrelated A", item_type: "feature", board_state: "pending")
    b = @project.tasks.create!(title: "Unrelated B", item_type: "feature", board_state: "pending")
    Board::Consolidator.stub(:detect_related, ->(_task, _cands) { [] }) do
      Board::Consolidator.run!(b)
    end
    assert_nil b.reload.merged_into_id
  end

  test "run! considers only pending unmerged candidates" do
    flight  = @project.tasks.create!(title: "In flight", item_type: "feature", board_state: "in_progress")
    pending = @project.tasks.create!(title: "Pending sib", item_type: "feature", board_state: "pending")
    b = @project.tasks.create!(title: "New", item_type: "feature", board_state: "pending")
    captured = nil
    Board::Consolidator.stub(:detect_related, ->(_t, cands) { captured = cands.map(&:id); [] }) do
      Board::Consolidator.run!(b)
    end
    assert_includes captured, pending.id
    assert_not_includes captured, flight.id, "in_progress items are not candidates"
  end
end
