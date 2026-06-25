require "test_helper"

class TaskJiraBacklinkTest < ActionDispatch::IntegrationTest
  test "task show links external_ref back to Jira when external_url is set" do
    project = Project.create!(name: "Acme", slug: "acme-bl")
    task = project.tasks.create!(title: "Login breaks", external_ref: "ENG-7",
                                 external_url: "https://acme.atlassian.net/browse/ENG-7",
                                 source: "jira", board_state: "pending")
    get project_task_path(project, task)
    assert_response :success
    assert_select "a[href=?]", "https://acme.atlassian.net/browse/ENG-7"
  end

  test "task show shows external_ref as plain text when no external_url" do
    project = Project.create!(name: "Acme", slug: "acme-bl2")
    task = project.tasks.create!(title: "Manual item", external_ref: "REF-1", board_state: "pending")
    get project_task_path(project, task)
    assert_response :success
    assert_match "REF-1", response.body
    assert_select "a[href=?]", "REF-1", count: 0
  end
end
