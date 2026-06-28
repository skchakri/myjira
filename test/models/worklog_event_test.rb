require "test_helper"

# WorklogEvent is the append-only timeline node. These cover the persistence
# entry point (record!), the chronological scope, and the duration helper the
# view uses for the "+Ns" chip — no event reporter involved.
class WorklogEventTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "WE", slug: "we-#{SecureRandom.hex(3)}", repo_path: "/tmp/we")
    @task = @project.tasks.create!(title: "x", item_type: "task", board_state: "pending")
  end

  test "record! creates a row and derives project from the subject" do
    e = WorklogEvent.record!(subject: @task, name: "board.in_review", status: "running", label: "→ In review")
    assert e.persisted?
    assert_equal @task, e.subject
    assert_equal @project.id, e.project_id, "project is derived from the subject"
    assert_equal "board.in_review", e.name
    assert_equal "running", e.status
    assert_not_nil e.occurred_at
  end

  test "record! truncates the label to MAX_LABEL" do
    e = WorklogEvent.record!(subject: @task, name: "n", status: "info", label: "a" * 500)
    assert_equal WorklogEvent::MAX_LABEL, e.label.length
  end

  test "record! rejects an unknown status" do
    assert_raises(ActiveRecord::RecordInvalid) do
      WorklogEvent.record!(subject: @task, name: "n", status: "bogus", label: "x")
    end
  end

  test "chronological orders by occurred_at" do
    base = Time.current
    c = WorklogEvent.record!(subject: @task, name: "c", status: "info", label: "c", occurred_at: base + 2)
    a = WorklogEvent.record!(subject: @task, name: "a", status: "info", label: "a", occurred_at: base)
    b = WorklogEvent.record!(subject: @task, name: "b", status: "info", label: "b", occurred_at: base + 1)
    assert_equal [a, b, c], @task.worklog_events.chronological.to_a
  end

  test "duration_since returns whole seconds, or nil with no prior node" do
    base = Time.current
    prev = WorklogEvent.record!(subject: @task, name: "p", status: "info", label: "p", occurred_at: base)
    cur  = WorklogEvent.record!(subject: @task, name: "c", status: "info", label: "c", occurred_at: base + 3)
    assert_equal 3, cur.duration_since(prev)
    assert_nil cur.duration_since(nil)
  end
end
