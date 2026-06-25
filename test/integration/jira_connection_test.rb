require "test_helper"

class JiraConnectionFlowTest < ActionDispatch::IntegrationTest
  test "edit renders the form" do
    get edit_jira_connection_path
    assert_response :success
    assert_select "form"
  end

  test "update saves credentials" do
    patch jira_connection_path, params: { jira_connection: {
      site_url: "https://acme.atlassian.net", email: "a@b.com", api_token: "tok123"
    } }
    assert_redirected_to edit_jira_connection_path
    c = JiraConnection.current
    assert_equal "a@b.com", c.email
    assert_equal "tok123", c.api_token
  end

  test "blank token on update leaves the existing token intact" do
    JiraConnection.create!(site_url: "https://acme.atlassian.net", email: "a@b.com", api_token: "keepme")
    patch jira_connection_path, params: { jira_connection: {
      site_url: "https://acme.atlassian.net", email: "new@b.com", api_token: ""
    } }
    c = JiraConnection.current
    assert_equal "new@b.com", c.email
    assert_equal "keepme", c.api_token
  end
end
