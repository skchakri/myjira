require "test_helper"

class FollowUpTaskTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "F", slug: "f-#{SecureRandom.hex(3)}", repo_path: "/tmp/f")
  end

  # The Labelable concern is shared with Task — confirm it behaves identically
  # on follow-ups (normalization, the GIN-backed scope, and the distinct set).
  test "labels normalize on a follow-up" do
    fu = @project.follow_up_tasks.create!(title: "Gap", kind: "gap", severity: "medium",
                                          status: "open", labels: ["Flaky", " flaky ", ""])
    assert_equal ["flaky"], fu.reload.labels
  end

  test "with_label filters follow-ups" do
    hit = @project.follow_up_tasks.create!(title: "A", kind: "gap", severity: "low",
                                           status: "open", labels: ["needs-human"])
    miss = @project.follow_up_tasks.create!(title: "B", kind: "bug", severity: "low",
                                            status: "open", labels: ["flaky"])
    result = @project.follow_up_tasks.with_label("needs-human")
    assert_includes result, hit
    assert_not_includes result, miss
  end

  test "all_labels on follow-ups returns the distinct sorted set" do
    @project.follow_up_tasks.create!(title: "A", kind: "gap", severity: "low", status: "open",
                                     labels: ["flaky", "needs-human"])
    @project.follow_up_tasks.create!(title: "B", kind: "gap", severity: "low", status: "open",
                                     labels: ["flaky"])
    assert_equal ["flaky", "needs-human"], @project.follow_up_tasks.all_labels
  end
end
