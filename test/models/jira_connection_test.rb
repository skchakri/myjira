require "test_helper"

class JiraConnectionTest < ActiveSupport::TestCase
  def conn(**over)
    JiraConnection.new({ site_url: "https://acme.atlassian.net", email: "a@b.com", api_token: "tok123" }.merge(over))
  end

  test "encrypts the api_token at rest" do
    c = conn
    c.save!
    raw = JiraConnection.connection.select_value("SELECT api_token FROM jira_connections WHERE id = '#{c.id}'")
    refute_equal "tok123", raw, "token should not be stored in plaintext"
    assert_equal "tok123", JiraConnection.find(c.id).api_token
  end

  test "complete? requires all three fields" do
    assert conn.complete?
    refute conn(api_token: "").complete?
    refute conn(email: nil).complete?
  end

  test "host is derived from site_url" do
    assert_equal "acme.atlassian.net", conn.host
  end

  test "auth_header is basic base64 of email:token" do
    expected = "Basic " + Base64.strict_encode64("a@b.com:tok123")
    assert_equal expected, conn.auth_header
  end

  test "api_base appends the v3 path" do
    assert_equal "https://acme.atlassian.net/rest/api/3", conn.api_base
  end

  test "class configured? reflects the singleton row" do
    refute JiraConnection.configured?
    conn.save!
    assert JiraConnection.configured?
  end
end
