require "test_helper"

class TaskCommentTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "TC", slug: "tc-#{SecureRandom.hex(3)}", repo_path: "/tmp/tc")
    @task = @project.tasks.create!(title: "Item", item_type: "task")
  end

  test "requires a body" do
    c = @task.comments.build(author: "you", body: "")
    refute c.valid?
    assert_includes c.errors[:body], "can't be blank"
  end

  test "defaults author to 'you' and belongs to its task" do
    c = @task.comments.create!(body: "first note")
    assert_equal "you", c.author
    assert_equal @task.id, c.task_id
  end

  test "task#comments returns them oldest-first" do
    older = @task.comments.create!(body: "older", created_at: 2.minutes.ago)
    newer = @task.comments.create!(body: "newer")
    assert_equal [older.id, newer.id], @task.comments.pluck(:id)
  end

  test "deleting a task deletes its comments" do
    @task.comments.create!(body: "bye")
    assert_difference -> { TaskComment.count }, -1 do
      @task.destroy
    end
  end
end
