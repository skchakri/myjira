require "test_helper"

class Board::GapImporterTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "GI", slug: "gi-#{SecureRandom.hex(3)}", repo_path: "/tmp/gi")
  end

  def gap(title, **attrs)
    @project.follow_up_tasks.create!({ title: title, status: "open", kind: "gap", severity: "medium" }.merge(attrs))
  end

  test "import creates a pending board item per open gap and resolves the gap" do
    gap("Add dark mode toggle to settings panel")
    gap("Broken pagination on the runs index page", kind: "bug", severity: "high")

    result = Board::GapImporter.import(@project)

    assert_equal 2, result[:created]
    assert_equal 2, @project.tasks.where(board_state: "pending").count
    assert @project.follow_up_tasks.where(status: "open").none?, "imported gaps are resolved"
  end

  test "imported items carry NULL position — the importer no longer writes display order" do
    gap("Urgent crash on the board reorder endpoint", severity: "critical")
    gap("Minor typo in the empty-state copy", severity: "low")

    Board::GapImporter.import(@project)

    positions = @project.tasks.where(board_state: "pending").pluck(:position)
    assert_equal [nil, nil], positions,
                 "display position is left to genuine drags; the queue order is board_queue_ordered"
  end
end
