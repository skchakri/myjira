require "test_helper"

class PlaybookRunTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "PR", slug: "pr-#{SecureRandom.hex(3)}", repo_path: "/tmp/pr")
    @playbook = @project.playbooks.create!(name: "x", body: "y")
  end

  test "result must be one of RESULTS" do
    run = @playbook.playbook_runs.new(result: "maybe")
    assert_not run.valid?
    run.result = "passed"
    assert run.valid?
  end

  test "evaluate! records result, notes and a timestamp" do
    run = @playbook.playbook_runs.create!(result: "pending")
    run.evaluate!(result: "failed", notes: "Two specs red.")
    assert_equal "failed", run.result
    assert_equal "Two specs red.", run.notes
    assert_not_nil run.evaluated_at
  end
end
