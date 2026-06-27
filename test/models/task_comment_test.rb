require "test_helper"
require "turbo/broadcastable/test_helper"

class TaskCommentTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

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

  test "creating a comment broadcasts a live refresh to the task activity stream" do
    assert_turbo_stream_broadcasts [@task, :activity], count: 1 do
      @task.comments.create!(author: "engineer", body: "Direction: do X.")
    end
  end
end
