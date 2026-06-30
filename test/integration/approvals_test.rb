require "test_helper"

class ApprovalsTest < ActionDispatch::IntegrationTest
  test "the inbox lists awaiting-approval and needs-input items, skipping archived projects" do
    project = Project.create!(name: "Inbox", slug: "inbox-#{SecureRandom.hex(3)}", repo_path: "/tmp/inbox")
    approve_item = project.tasks.create!(title: "Approve me", item_type: "feature", board_state: "waiting",
                                         wait_reason: "awaiting_approval", agent_role: "engineering", plan: "p")
    project.tasks.create!(title: "Answer me", item_type: "feature", board_state: "waiting",
                          wait_reason: "needs_input",
                          pending_questions: [{ "id" => "q1", "q" => "Which?", "a" => nil }])
    archived = Project.create!(name: "Old", slug: "old-#{SecureRandom.hex(3)}", repo_path: "/tmp/old",
                               archived_at: Time.current)
    archived.tasks.create!(title: "Hidden", item_type: "feature", board_state: "waiting",
                           wait_reason: "awaiting_approval", plan: "x")

    get approvals_path
    assert_response :success
    assert_match "Approve me", response.body
    assert_match "Answer me", response.body
    assert_no_match(/Hidden/, response.body)
    assert_select "form[action=?]", board_item_approve_path(project, approve_item)
  end
end
