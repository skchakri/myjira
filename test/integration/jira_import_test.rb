require "test_helper"

class JiraImportFlowTest < ActionDispatch::IntegrationTest
  def setup
    @project = Project.create!(name: "Acme", slug: "acme-imp")
  end

  test "without a configured connection it alerts and creates nothing" do
    post project_jira_imports_path(@project), params: { url: "https://acme.atlassian.net/browse/ENG-7" }
    assert_redirected_to board_path(@project)
    assert_equal 0, @project.tasks.count
    follow_redirect!
    assert_match(/connect jira/i, flash[:alert].to_s + response.body)
  end

  test "success redirects to the board with a notice naming the item" do
    JiraConnection.create!(site_url: "https://acme.atlassian.net", email: "a@b.com", api_token: "tok")
    task = @project.tasks.create!(title: "Login breaks", external_ref: "ENG-7", source: "jira", board_state: "pending")
    result = Jira::Importer::Result.new(task: task, created: true, attachments_added: 2, attachments_skipped: [])

    Jira::Importer.stub(:import, result) do
      post project_jira_imports_path(@project), params: { url: "https://acme.atlassian.net/browse/ENG-7" }
    end
    assert_redirected_to board_path(@project)
    assert_match(/ENG-7/, flash[:notice])
    assert_match(/Login breaks/, flash[:notice])
    assert_match(/2 attachment/, flash[:notice])
  end

  test "notice reports attachments that could not be downloaded" do
    JiraConnection.create!(site_url: "https://acme.atlassian.net", email: "a@b.com", api_token: "tok")
    task = @project.tasks.create!(title: "Login breaks", external_ref: "ENG-7", source: "jira", board_state: "pending")
    result = Jira::Importer::Result.new(task: task, created: false, attachments_added: 1, attachments_skipped: ["big.zip"])

    Jira::Importer.stub(:import, result) do
      post project_jira_imports_path(@project), params: { url: "https://acme.atlassian.net/browse/ENG-7" }
    end
    assert_match(/Updated/, flash[:notice])
    assert_match(/could.?n.?t be downloaded/i, flash[:notice])
  end

  test "a Jira::Error becomes a friendly alert" do
    JiraConnection.create!(site_url: "https://acme.atlassian.net", email: "a@b.com", api_token: "tok")
    raiser = ->(**) { raise Jira::Error.new("Jira rejected the credentials.", kind: :unauthorized) }
    Jira::Importer.stub(:import, raiser) do
      post project_jira_imports_path(@project), params: { url: "https://acme.atlassian.net/browse/ENG-7" }
    end
    assert_redirected_to board_path(@project)
    assert_match(/credentials/i, flash[:alert])
  end
end
