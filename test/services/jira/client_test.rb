require "test_helper"

class Jira::ClientTest < ActiveSupport::TestCase
  # Minimal duck-typed stand-in for a Net::HTTPResponse.
  FakeResp = Struct.new(:code, :body, :headers) do
    def [](k) = (headers || {})[k]
  end

  def connection
    JiraConnection.new(site_url: "https://acme.atlassian.net", email: "a@b.com", api_token: "tok")
  end

  def issue_json
    {
      "key" => "ENG-7",
      "fields" => {
        "summary" => "Login breaks",
        "description" => { "type" => "doc", "content" => [] },
        "issuetype" => { "name" => "Bug" },
        "priority"  => { "name" => "High" },
        "status"    => { "name" => "To Do" },
        "assignee"  => { "displayName" => "Jane" },
        "reporter"  => { "displayName" => "Bob" },
        "labels"    => ["login"],
        "comment"   => { "comments" => [
          { "author" => { "displayName" => "Jane" }, "created" => "2026-06-01", "body" => { "type" => "doc", "content" => [] } }
        ] },
        "attachment" => [
          { "filename" => "shot.png", "mimeType" => "image/png", "size" => 12, "content" => "https://acme.atlassian.net/secure/content/1" }
        ]
      }
    }
  end

  test "fetch_issue normalizes the Jira JSON" do
    client = Jira::Client.new(connection)
    client.stub(:request, FakeResp.new("200", issue_json.to_json, {})) do
      i = client.fetch_issue("ENG-7")
      assert_equal "ENG-7", i[:key]
      assert_equal "Login breaks", i[:summary]
      assert_equal "Bug", i[:issue_type]
      assert_equal "High", i[:priority]
      assert_equal ["login"], i[:labels]
      assert_equal "Jane", i[:comments].first[:author]
      assert_equal "shot.png", i[:attachments].first[:filename]
      assert_equal 12, i[:attachments].first[:size]
    end
  end

  test "401 raises unauthorized" do
    client = Jira::Client.new(connection)
    client.stub(:request, FakeResp.new("401", "", {})) do
      err = assert_raises(Jira::Error) { client.fetch_issue("ENG-7") }
      assert_equal :unauthorized, err.kind
    end
  end

  test "404 raises not_found" do
    client = Jira::Client.new(connection)
    client.stub(:request, FakeResp.new("404", "", {})) do
      err = assert_raises(Jira::Error) { client.fetch_issue("ENG-7") }
      assert_equal :not_found, err.kind
    end
  end

  test "download_attachment returns io + content_type" do
    client = Jira::Client.new(connection)
    client.stub(:request, FakeResp.new("200", "PNGBYTES", { "content-type" => "image/png" })) do
      blob = client.download_attachment("https://acme.atlassian.net/secure/content/1")
      assert_equal "PNGBYTES", blob[:io].read
      assert_equal "image/png", blob[:content_type]
    end
  end

  test "download_attachment follows a redirect to the signed media URL" do
    client = Jira::Client.new(connection)
    responder = lambda do |uri|
      if uri.to_s.include?("/secure/content/1")
        FakeResp.new("302", "", { "location" => "https://media.example.com/signed/abc" })
      else
        FakeResp.new("200", "REALBYTES", { "content-type" => "image/png" })
      end
    end
    client.stub(:request, responder) do
      blob = client.download_attachment("https://acme.atlassian.net/secure/content/1")
      assert_equal "REALBYTES", blob[:io].read
      assert_equal "image/png", blob[:content_type]
    end
  end

  test "403 raises not_found" do
    client = Jira::Client.new(connection)
    client.stub(:request, FakeResp.new("403", "", {})) do
      err = assert_raises(Jira::Error) { client.fetch_issue("ENG-7") }
      assert_equal :not_found, err.kind
    end
  end

  test "malformed JSON raises request_error" do
    client = Jira::Client.new(connection)
    client.stub(:request, FakeResp.new("200", "not json", {})) do
      err = assert_raises(Jira::Error) { client.fetch_issue("ENG-7") }
      assert_equal :request_error, err.kind
    end
  end
end
