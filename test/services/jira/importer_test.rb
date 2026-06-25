require "test_helper"

class Jira::ImporterTest < ActiveSupport::TestCase
  # Stand-in for Jira::Client: returns a canned normalized issue + fake bytes.
  class FakeClient
    attr_reader :downloads
    def initialize(issue, bytes = "img")
      @issue = issue
      @bytes = bytes
      @downloads = 0
    end

    def fetch_issue(_key) = @issue
    def download_attachment(_url)
      @downloads += 1
      { io: StringIO.new(@bytes), content_type: "image/png" }
    end
  end

  def setup
    @project = Project.create!(name: "Acme", slug: "acme-jira")
    @conn = JiraConnection.create!(site_url: "https://acme.atlassian.net", email: "a@b.com", api_token: "tok")
  end

  def issue(**over)
    {
      key: "ENG-7", summary: "Login breaks",
      description_adf: { "type" => "doc", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Boom" }] }] },
      issue_type: "Bug", priority: "High", status: "To Do", assignee: "Jane", reporter: "Bob", labels: [],
      comments: [], attachments: []
    }.merge(over)
  end

  def import(url: "https://acme.atlassian.net/browse/ENG-7", client:)
    Jira::Importer.import(url: url, project: @project, connection: @conn, client: client)
  end

  test "creates a pending board item with mapped fields" do
    res = import(client: FakeClient.new(issue))
    t = res.task
    assert res.created
    assert_equal "Login breaks", t.title
    assert_equal "issue", t.item_type      # Bug → issue
    assert_equal "high", t.priority        # High → high
    assert_equal "pending", t.board_state
    assert_equal "jira", t.source
    assert_equal "ENG-7", t.external_ref
    assert_includes t.description, "Boom"
  end

  test "appends comments under a Comments heading" do
    i = issue(comments: [{ author: "Jane", created: "2026-06-01",
                           body_adf: { "type" => "doc", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Me too" }] }] } }])
    res = import(client: FakeClient.new(i))
    assert_includes res.task.description, "### Comments"
    assert_includes res.task.description, "Me too"
  end

  test "re-import updates the same item and preserves board_state" do
    res1 = import(client: FakeClient.new(issue))
    res1.task.update!(board_state: "in_progress")            # human moved it

    res2 = import(client: FakeClient.new(issue(summary: "Login totally breaks")))
    refute res2.created
    assert_equal res1.task.id, res2.task.id
    assert_equal 1, @project.tasks.where(external_ref: "ENG-7").count
    assert_equal "Login totally breaks", res2.task.title     # field refreshed
    assert_equal "in_progress", res2.task.reload.board_state # state preserved
  end

  test "downloads attachments and dedupes by filename + size on re-import" do
    att = { filename: "a.png", mime: "image/png", size: 3, content_url: "https://acme.atlassian.net/secure/content/1" }
    client1 = FakeClient.new(issue(attachments: [att]))
    res1 = import(client: client1)
    assert_equal 1, res1.attachments_added
    assert_equal 1, res1.task.attachments.count

    client2 = FakeClient.new(issue(attachments: [att]))  # same file
    res2 = import(client: client2)
    assert_equal 0, res2.attachments_added               # deduped
    assert_equal 0, client2.downloads                    # not even downloaded
    assert_equal 1, res2.task.reload.attachments.count
  end

  test "rejects a URL whose host does not match the connection" do
    err = assert_raises(Jira::Error) do
      Jira::Importer.import(url: "https://evil.example.com/browse/ENG-7",
                            project: @project, connection: @conn, client: FakeClient.new(issue))
    end
    assert_equal :bad_url, err.kind
  end

  test "accepts a URL whose host differs only in case" do
    res = Jira::Importer.import(url: "https://ACME.atlassian.net/browse/ENG-7",
                                project: @project, connection: @conn, client: FakeClient.new(issue))
    assert res.created
    assert_equal "ENG-7", res.task.external_ref
  end

  test "raises not_configured when the connection is incomplete" do
    bare = JiraConnection.new(site_url: "https://acme.atlassian.net")  # no email/token
    err = assert_raises(Jira::Error) do
      Jira::Importer.import(url: "https://acme.atlassian.net/browse/ENG-7",
                            project: @project, connection: bare, client: FakeClient.new(issue))
    end
    assert_equal :not_configured, err.kind
  end
end
