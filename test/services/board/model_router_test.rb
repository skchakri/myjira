require "test_helper"

class Board::ModelRouterTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "MR", slug: "mr-#{SecureRandom.hex(3)}", repo_path: "/tmp/mr")
  end

  def task(**attrs)
    @project.tasks.create!({ title: "t", item_type: "task" }.merge(attrs))
  end

  test "answer step routes to haiku" do
    assert_equal "haiku", Board::ModelRouter.pick(task: task(item_type: "feature"), step: "answer")
  end

  test "short ask item routes to haiku" do
    assert_equal "haiku", Board::ModelRouter.pick(task: task(item_type: "ask", description: "How does X work?"), step: "answer")
  end

  test "urgent item escalates to opus" do
    assert_equal "opus", Board::ModelRouter.pick(task: task(priority: "urgent"), step: "engineering")
  end

  test "already-failed-once item escalates to opus" do
    assert_equal "opus", Board::ModelRouter.pick(task: task(autopilot_attempts: 1), step: "engineering")
  end

  test "long description escalates to opus" do
    assert_equal "opus", Board::ModelRouter.pick(task: task(description: "x" * 1300), step: "engineering")
  end

  test "multi-file label escalates to opus" do
    assert_equal "opus", Board::ModelRouter.pick(task: task(labels: ["multi-file"]), step: "engineering")
  end

  test "typical engineering item routes to sonnet" do
    assert_equal "sonnet", Board::ModelRouter.pick(task: task(item_type: "feature", description: "Add a button"), step: "engineering")
  end

  test "opus signals win over cheap signals" do
    # urgent short ask on answer step still escalates
    assert_equal "opus", Board::ModelRouter.pick(task: task(item_type: "ask", priority: "urgent", description: "tiny"), step: "answer")
  end

  test "nil description and attempts do not raise and fall back to sonnet" do
    t = task(item_type: "feature", description: nil)
    assert_equal "sonnet", Board::ModelRouter.pick(task: t, step: "engineering")
  end

  test "ask item with a long description is not cheap" do
    # long ask description (>=400) shouldn't trigger Haiku; falls through to Sonnet
    assert_equal "sonnet", Board::ModelRouter.pick(task: task(item_type: "ask", description: "x" * 500), step: "planning")
  end
end
