# Jira Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an "Import from Jira" button to each project board that pulls an Atlassian Jira ticket (by URL) into myjira as a fully-formed, idempotently-updated board item — title, description, type, priority, comments, and attachments.

**Architecture:** A singleton `JiraConnection` model (encrypted token) holds credentials. `Jira::Client` (stdlib `net/http`) fetches + normalizes the issue and downloads attachments. `Jira::AdfConverter` turns Atlassian Document Format into Markdown. `Jira::Importer` orchestrates fetch → map → `find_or_initialize_by(external_ref:)` → save → attach. Thin controllers (`JiraImportsController`, `JiraConnectionsController`) drive a board-header modal and a settings form.

**Tech Stack:** Rails 8, PostgreSQL (UUID PKs), Active Storage, Active Record Encryption, Hotwire/Stimulus, Tailwind v4. Tests: Minitest (no WebMock/Mocha — HTTP is stubbed via dependency injection + Minitest's built-in `Object#stub`).

**Spec:** `docs/superpowers/specs/2026-06-24-jira-import-design.md`

**Conventions in this repo (follow exactly):**
- Reuse existing Tailwind utility classes/tokens only (`pill`, `pill-quiet`, `pill-accent`, `paper`, `hair-b`, `eyebrow`, `text-[color:var(--color-*)]`). Do **not** invent new arbitrary classes (Tailwind build gotcha).
- Services live in `app/services/jira/`; the `Jira` module is an implicit Zeitwerk namespace (no `jira.rb` needed).
- Tests build their own records (no fixtures), mirroring `test/integration/board_test.rb`.
- Commits: user is sole author, **no** `Co-Authored-By` line (per global CLAUDE.md).

---

### Task 1: Schema + `JiraConnection` model

**Files:**
- Create: `db/migrate/20260624000001_create_jira_connections.rb`
- Create: `db/migrate/20260624000002_add_external_url_to_tasks.rb`
- Create: `app/models/jira_connection.rb`
- Test: `test/models/jira_connection_test.rb`

- [ ] **Step 1: Verify Active Record Encryption keys exist (guard)**

Run:
```bash
cd /home/kalyan/platform/skchakri/myjira
bin/rails runner 'puts ActiveRecord::Encryption.config.primary_key.present? ? "ENC OK" : "ENC MISSING"'
```
Expected: `ENC OK` (the app already uses `encrypts :env` in `app/models/mcp_install.rb`).
If it prints `ENC MISSING`, run `bin/rails db:encryption:init` and add the three printed keys under `active_record_encryption:` in `bin/rails credentials:edit`, then re-run the check before continuing.

- [ ] **Step 2: Write the migrations**

`db/migrate/20260624000001_create_jira_connections.rb`:
```ruby
class CreateJiraConnections < ActiveRecord::Migration[8.0]
  def change
    create_table :jira_connections, id: :uuid do |t|
      t.string :site_url
      t.string :email
      t.text   :api_token   # encrypted at rest via ActiveRecord::Encryption
      t.timestamps
    end
  end
end
```

`db/migrate/20260624000002_add_external_url_to_tasks.rb`:
```ruby
class AddExternalUrlToTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :tasks, :external_url, :string
  end
end
```

- [ ] **Step 3: Run the migrations**

Run: `bin/rails db:migrate`
Expected: both migrations run; `db/schema.rb` now shows `external_url` on `tasks` and a `jira_connections` table.

- [ ] **Step 4: Write the failing model test**

`test/models/jira_connection_test.rb`:
```ruby
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
```

- [ ] **Step 5: Run it to verify it fails**

Run: `bin/rails test test/models/jira_connection_test.rb`
Expected: FAIL — `uninitialized constant JiraConnection`.

- [ ] **Step 6: Write the model**

`app/models/jira_connection.rb`:
```ruby
require "base64"
require "uri"

# Singleton credentials for the Atlassian Jira Cloud REST API. One row: the
# account whose email + API token myjira uses to read tickets on import. The
# token is encrypted at rest (Active Record Encryption).
class JiraConnection < ApplicationRecord
  encrypts :api_token

  validates :site_url, presence: true

  # The single configured connection (or nil / a fresh unsaved one).
  def self.current      = first
  def self.current_or_new = first || new
  def self.configured?  = current&.complete? || false

  def complete?
    site_url.present? && email.present? && api_token.present?
  end

  def host
    URI.parse(site_url.to_s).host
  rescue URI::InvalidURIError
    nil
  end

  def api_base
    "#{site_url.to_s.chomp('/')}/rest/api/3"
  end

  def auth_header
    "Basic " + Base64.strict_encode64("#{email}:#{api_token}")
  end
end
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/models/jira_connection_test.rb`
Expected: PASS (6 runs, 0 failures).

- [ ] **Step 8: Commit**

```bash
git add db/migrate/20260624000001_create_jira_connections.rb db/migrate/20260624000002_add_external_url_to_tasks.rb db/schema.rb app/models/jira_connection.rb test/models/jira_connection_test.rb
git commit -m "Add JiraConnection model + external_url column"
```

---

### Task 2: `Jira::Error` + `Jira::Client`

**Files:**
- Create: `app/services/jira/error.rb`
- Create: `app/services/jira/client.rb`
- Test: `test/services/jira/client_test.rb`

- [ ] **Step 1: Write the error class**

`app/services/jira/error.rb`:
```ruby
module Jira
  # One error type carrying a kind symbol; controllers map kind → user message.
  # kinds: :not_configured, :bad_url, :unauthorized, :not_found, :request_error
  class Error < StandardError
    attr_reader :kind

    def initialize(message, kind: :request_error)
      super(message)
      @kind = kind
    end

    def user_message = message
  end
end
```

- [ ] **Step 2: Write the failing client test**

`test/services/jira/client_test.rb`:
```ruby
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
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bin/rails test test/services/jira/client_test.rb`
Expected: FAIL — `uninitialized constant Jira::Client`.

- [ ] **Step 4: Write the client**

`app/services/jira/client.rb`:
```ruby
require "net/http"
require "json"
require "uri"
require "stringio"

module Jira
  # Thin wrapper over the Jira Cloud REST API v3 using stdlib net/http. Fetches
  # and normalizes an issue, and downloads attachment bytes. All failures become
  # Jira::Error with a kind the controller can turn into a friendly message.
  class Client
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 15
    ISSUE_FIELDS = "summary,description,issuetype,priority,status,assignee,reporter,labels,comment,attachment".freeze

    def initialize(connection)
      @connection = connection
    end

    def fetch_issue(key)
      resp = request(:get, URI.parse("#{@connection.api_base}/issue/#{key}?fields=#{ISSUE_FIELDS}"))
      ok!(resp)
      normalize_issue(parse_json(resp.body))
    end

    def download_attachment(content_url)
      resp = request(:get, URI.parse(content_url))
      ok!(resp)
      { io: StringIO.new(resp.body.to_s), content_type: resp["content-type"] }
    end

    private

    def request(_method, uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = @connection.auth_header
      req["Accept"] = "application/json"
      http.request(req)
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, OpenSSL::SSL::SSLError => e
      raise Jira::Error.new("Couldn’t reach Jira (#{e.class}).", kind: :request_error)
    end

    def ok!(resp)
      code = resp.code.to_i
      return if code.between?(200, 299)
      case code
      when 401 then raise Jira::Error.new("Jira rejected the credentials.", kind: :unauthorized)
      when 403, 404 then raise Jira::Error.new("That Jira issue wasn’t found, or you don’t have access.", kind: :not_found)
      else raise Jira::Error.new("Jira request failed (HTTP #{code}).", kind: :request_error)
      end
    end

    def parse_json(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      raise Jira::Error.new("Jira returned an unexpected response.", kind: :request_error)
    end

    def normalize_issue(json)
      f = json["fields"] || {}
      {
        key: json["key"],
        summary: f["summary"],
        description_adf: f["description"],
        issue_type: f.dig("issuetype", "name"),
        priority: f.dig("priority", "name"),
        status: f.dig("status", "name"),
        assignee: f.dig("assignee", "displayName"),
        reporter: f.dig("reporter", "displayName"),
        labels: Array(f["labels"]),
        comments: Array(f.dig("comment", "comments")).map do |c|
          { author: c.dig("author", "displayName"), created: c["created"], body_adf: c["body"] }
        end,
        attachments: Array(f["attachment"]).map do |a|
          { filename: a["filename"], mime: a["mimeType"], size: a["size"].to_i, content_url: a["content"] }
        end
      }
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/services/jira/client_test.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add app/services/jira/error.rb app/services/jira/client.rb test/services/jira/client_test.rb
git commit -m "Add Jira::Client + Jira::Error (REST v3 fetch/normalize/download)"
```

---

### Task 3: `Jira::AdfConverter`

**Files:**
- Create: `app/services/jira/adf_converter.rb`
- Test: `test/services/jira/adf_converter_test.rb`

- [ ] **Step 1: Write the failing test**

`test/services/jira/adf_converter_test.rb`:
```ruby
require "test_helper"

class Jira::AdfConverterTest < ActiveSupport::TestCase
  def conv(node) = Jira::AdfConverter.to_markdown(node)

  test "nil and empty become empty string" do
    assert_equal "", conv(nil)
    assert_equal "", conv({})
  end

  test "paragraph with text" do
    doc = { "type" => "doc", "content" => [
      { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello world" }] }
    ] }
    assert_equal "Hello world", conv(doc)
  end

  test "marks: strong, em, code, link" do
    doc = { "type" => "doc", "content" => [{ "type" => "paragraph", "content" => [
      { "type" => "text", "text" => "bold", "marks" => [{ "type" => "strong" }] },
      { "type" => "text", "text" => " and " },
      { "type" => "text", "text" => "link", "marks" => [{ "type" => "link", "attrs" => { "href" => "https://x.test" } }] }
    ] }] }
    assert_equal "**bold** and [link](https://x.test)", conv(doc)
  end

  test "heading" do
    doc = { "type" => "doc", "content" => [
      { "type" => "heading", "attrs" => { "level" => 2 }, "content" => [{ "type" => "text", "text" => "Title" }] }
    ] }
    assert_equal "## Title", conv(doc)
  end

  test "bullet list" do
    doc = { "type" => "doc", "content" => [
      { "type" => "bulletList", "content" => [
        { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "one" }] }] },
        { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "two" }] }] }
      ] }
    ] }
    assert_equal "- one\n- two", conv(doc)
  end

  test "code block" do
    doc = { "type" => "doc", "content" => [
      { "type" => "codeBlock", "content" => [{ "type" => "text", "text" => "puts 1" }] }
    ] }
    assert_equal "```\nputs 1\n```", conv(doc)
  end

  test "hardBreak inside paragraph" do
    doc = { "type" => "doc", "content" => [{ "type" => "paragraph", "content" => [
      { "type" => "text", "text" => "a" }, { "type" => "hardBreak" }, { "type" => "text", "text" => "b" }
    ] }] }
    assert_equal "a\nb", conv(doc)
  end

  test "unknown node falls back to its inner text" do
    doc = { "type" => "doc", "content" => [
      { "type" => "panel", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "noted" }] }] }
    ] }
    assert_equal "noted", conv(doc)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/services/jira/adf_converter_test.rb`
Expected: FAIL — `uninitialized constant Jira::AdfConverter`.

- [ ] **Step 3: Write the converter**

`app/services/jira/adf_converter.rb`:
```ruby
module Jira
  # Converts an Atlassian Document Format (ADF) body — the JSON used by Jira
  # issue descriptions and comments — into Markdown. Unknown node types degrade
  # gracefully to the text they contain, so the converter never raises.
  module AdfConverter
    module_function

    def to_markdown(node)
      return "" if node.blank?
      render(node).strip
    end

    # Render a node to a string. Block nodes manage their own spacing.
    def render(node)
      return "" if node.nil?
      case node["type"]
      when "doc"        then block_children(node)
      when "paragraph"  then inline_children(node)
      when "heading"    then "#{'#' * (node.dig('attrs', 'level') || 1)} #{inline_children(node)}"
      when "text"       then apply_marks(node["text"].to_s, node["marks"])
      when "hardBreak"  then "\n"
      when "rule"       then "---"
      when "bulletList"  then list_children(node, "- ")
      when "orderedList" then ordered(node)
      when "listItem"   then inline_children(node)
      when "codeBlock"  then "```\n#{plain_text(node)}\n```"
      when "blockquote" then block_children(node).split("\n").map { |l| "> #{l}" }.join("\n")
      when "mention"    then node.dig("attrs", "text").to_s
      when "emoji"      then node.dig("attrs", "text").to_s
      when "inlineCard" then node.dig("attrs", "url").to_s
      else
        # Unknown: prefer block layout if it has block children, else inline.
        node["content"] ? block_children(node) : inline_children(node)
      end
    end

    # Join block-level children with blank lines between them.
    def block_children(node)
      Array(node["content"]).map { |c| render(c) }.reject(&:empty?).join("\n\n")
    end

    # Join inline children with no separator (text, marks, hardBreaks).
    def inline_children(node)
      Array(node["content"]).map { |c| render(c) }.join
    end

    def list_children(node, bullet)
      Array(node["content"]).map { |li| "#{bullet}#{render(li)}" }.join("\n")
    end

    def ordered(node)
      Array(node["content"]).each_with_index.map { |li, i| "#{i + 1}. #{render(li)}" }.join("\n")
    end

    # Flatten any subtree to its raw text (for code blocks).
    def plain_text(node)
      return node["text"].to_s if node["type"] == "text"
      Array(node["content"]).map { |c| plain_text(c) }.join
    end

    def apply_marks(text, marks)
      Array(marks).inject(text) do |acc, mark|
        case mark["type"]
        when "strong" then "**#{acc}**"
        when "em"     then "*#{acc}*"
        when "code"   then "`#{acc}`"
        when "strike" then "~~#{acc}~~"
        when "link"   then "[#{acc}](#{mark.dig('attrs', 'href')})"
        else acc
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/services/jira/adf_converter_test.rb`
Expected: PASS (8 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add app/services/jira/adf_converter.rb test/services/jira/adf_converter_test.rb
git commit -m "Add Jira::AdfConverter (ADF → Markdown)"
```

---

### Task 4: `Jira::Importer`

**Files:**
- Create: `app/services/jira/importer.rb`
- Test: `test/services/jira/importer_test.rb`

- [ ] **Step 1: Write the failing test**

`test/services/jira/importer_test.rb`:
```ruby
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

  test "raises not_configured when the connection is incomplete" do
    bare = JiraConnection.new(site_url: "https://acme.atlassian.net")  # no email/token
    err = assert_raises(Jira::Error) do
      Jira::Importer.import(url: "https://acme.atlassian.net/browse/ENG-7",
                            project: @project, connection: bare, client: FakeClient.new(issue))
    end
    assert_equal :not_configured, err.kind
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/services/jira/importer_test.rb`
Expected: FAIL — `uninitialized constant Jira::Importer`.

- [ ] **Step 3: Write the importer**

`app/services/jira/importer.rb`:
```ruby
module Jira
  # Orchestrates importing one Jira issue into a project's board as a Task.
  # Idempotent on the Jira key (tasks.external_ref): re-import updates the same
  # item (refreshing Jira-derived fields) and never duplicates attachments.
  module Importer
    module_function

    Result = Struct.new(:task, :created, :attachments_added, :attachments_skipped, keyword_init: true)

    TYPE_MAP = {
      "Bug" => "issue", "Story" => "task", "Task" => "task", "Sub-task" => "task",
      "Epic" => "feature", "Improvement" => "feature", "New Feature" => "feature",
      "Question" => "ask"
    }.freeze
    PRIORITY_MAP = {
      "Highest" => "urgent", "Critical" => "urgent", "High" => "high",
      "Medium" => "normal", "Low" => "low", "Lowest" => "low"
    }.freeze

    def import(url:, project:, connection: JiraConnection.current, client: nil)
      raise Jira::Error.new("Connect Jira first.", kind: :not_configured) unless connection&.complete?

      key, host = parse(url)
      raise Jira::Error.new("That doesn’t look like a Jira ticket URL.", kind: :bad_url) if key.blank?
      if host && connection.host && host != connection.host
        raise Jira::Error.new("That URL isn’t for #{connection.host}.", kind: :bad_url)
      end

      client ||= Jira::Client.new(connection)
      issue = client.fetch_issue(key)

      task = project.tasks.find_or_initialize_by(external_ref: issue[:key])
      created = task.new_record?
      task.assign_attributes(
        title: issue[:summary].presence || issue[:key],
        description: build_description(issue),
        item_type: TYPE_MAP[issue[:issue_type]] || "task",
        priority: PRIORITY_MAP[issue[:priority]] || "normal",
        source: "jira",
        external_url: url
      )
      task.board_state = "pending" if created
      task.save!

      added, skipped = sync_attachments(task, issue, client)
      Result.new(task: task, created: created, attachments_added: added, attachments_skipped: skipped)
    end

    # Extract [issue_key, host] from a Jira URL (browse link or ?selectedIssue=).
    def parse(url)
      uri = URI.parse(url.to_s)
      key = uri.path.to_s[/[A-Z][A-Z0-9]+-\d+/] ||
            uri.query.to_s[/selectedIssue=([A-Z][A-Z0-9]+-\d+)/, 1]
      [key, uri.host]
    rescue URI::InvalidURIError
      [nil, nil]
    end

    def build_description(issue)
      parts = [Jira::AdfConverter.to_markdown(issue[:description_adf])]
      unless issue[:comments].empty?
        parts << "---\n\n### Comments"
        issue[:comments].each do |c|
          parts << "**#{c[:author]}** · #{c[:created]}\n\n#{Jira::AdfConverter.to_markdown(c[:body_adf])}"
        end
      end
      parts.reject(&:blank?).join("\n\n")
    end

    # Download + attach each Jira attachment not already present (matched by
    # filename + byte size). One bad download is skipped, not fatal.
    def sync_attachments(task, issue, client)
      added = 0
      skipped = []
      Array(issue[:attachments]).each do |att|
        if task.attachments.any? { |a| a.filename.to_s == att[:filename] && a.byte_size == att[:size] }
          next
        end
        begin
          blob = client.download_attachment(att[:content_url])
          task.attachments.attach(io: blob[:io], filename: att[:filename], content_type: blob[:content_type] || att[:mime])
          added += 1
        rescue Jira::Error
          skipped << att[:filename]
        end
      end
      [added, skipped]
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/services/jira/importer_test.rb`
Expected: PASS (7 runs, 0 failures).

- [ ] **Step 5: Run the whole service + model suite**

Run: `bin/rails test test/services test/models/jira_connection_test.rb`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add app/services/jira/importer.rb test/services/jira/importer_test.rb
git commit -m "Add Jira::Importer (idempotent issue → board item)"
```

---

### Task 5: Routes + `JiraConnectionsController` + settings form

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/jira_connections_controller.rb`
- Create: `app/views/jira_connections/edit.html.erb`
- Test: `test/integration/jira_connection_test.rb`

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, add inside the existing `scope "projects/:project_id" do ... end` block (next to the `board/items` routes):
```ruby
    post "jira_imports", to: "jira_imports#create", as: :jira_imports
```
And add these top-level routes (place them just after that `scope` block closes, near the other top-level board/autopilot routes):
```ruby
  # Global Jira connection (singleton credentials for ticket import).
  get   "jira/connection/edit", to: "jira_connections#edit",   as: :edit_jira_connection
  patch "jira/connection",      to: "jira_connections#update", as: :jira_connection
```

- [ ] **Step 2: Verify the routes resolve**

Run: `bin/rails routes -g jira`
Expected: shows `jira_imports` (POST), `edit_jira_connection` (GET), `jira_connection` (PATCH).

- [ ] **Step 3: Write the failing controller test**

`test/integration/jira_connection_test.rb`:
```ruby
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
```

- [ ] **Step 4: Run it to verify it fails**

Run: `bin/rails test test/integration/jira_connection_test.rb`
Expected: FAIL — routing/uninitialized-constant error for `JiraConnectionsController`.

- [ ] **Step 5: Write the controller**

`app/controllers/jira_connections_controller.rb`:
```ruby
# The single Jira credentials record used to import tickets. Singleton: edit
# always operates on the one row (or builds it). A blank api_token on update is
# ignored so saving other fields never wipes the stored secret.
class JiraConnectionsController < ApplicationController
  def edit
    @connection = JiraConnection.current_or_new
  end

  def update
    @connection = JiraConnection.current_or_new
    attrs = connection_params
    attrs = attrs.except(:api_token) if attrs[:api_token].blank?
    if @connection.update(attrs)
      redirect_to edit_jira_connection_path, notice: "Jira connection saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def connection_params
    params.require(:jira_connection).permit(:site_url, :email, :api_token)
  end
end
```

- [ ] **Step 6: Write the edit view**

`app/views/jira_connections/edit.html.erb`:
```erb
<% content_for :title, "Jira connection" %>

<div class="max-w-xl">
  <div class="eyebrow">Settings</div>
  <h1 class="font-display text-[32px] leading-tight tracking-tight mt-1 mb-4">Jira connection</h1>
  <p class="text-sm text-[color:var(--color-ink-soft)] mb-5">
    Credentials myjira uses to import tickets from Atlassian Jira Cloud. Create an API token at
    <a href="https://id.atlassian.com/manage-profile/security/api-tokens" class="text-[color:var(--color-amber-ink)] underline" target="_blank" rel="noopener">id.atlassian.com</a>.
  </p>

  <%= form_with model: @connection, url: jira_connection_path, method: :patch, scope: :jira_connection, class: "paper p-5 space-y-4" do |f| %>
    <label class="block">
      <span class="eyebrow block mb-1">Site URL</span>
      <%= f.url_field :site_url, placeholder: "https://your-site.atlassian.net",
            class: "w-full hair-all rounded px-3 py-2 text-sm bg-[color:var(--color-paper-raised)] focus:border-[color:var(--color-amber-ink)] outline-none" %>
    </label>
    <label class="block">
      <span class="eyebrow block mb-1">Atlassian email</span>
      <%= f.email_field :email, placeholder: "you@example.com",
            class: "w-full hair-all rounded px-3 py-2 text-sm bg-[color:var(--color-paper-raised)] focus:border-[color:var(--color-amber-ink)] outline-none" %>
    </label>
    <label class="block">
      <span class="eyebrow block mb-1">API token</span>
      <%= f.password_field :api_token, value: "", autocomplete: "off",
            placeholder: @connection.api_token.present? ? "•••••••• (leave blank to keep)" : "Paste your API token",
            class: "w-full hair-all rounded px-3 py-2 text-sm bg-[color:var(--color-paper-raised)] focus:border-[color:var(--color-amber-ink)] outline-none" %>
    </label>
    <div class="flex justify-end pt-1">
      <%= f.submit "Save", class: "pill pill-accent cursor-pointer" %>
    </div>
  <% end %>
</div>
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/integration/jira_connection_test.rb`
Expected: PASS (3 runs, 0 failures).

- [ ] **Step 8: Commit**

```bash
git add config/routes.rb app/controllers/jira_connections_controller.rb app/views/jira_connections/edit.html.erb test/integration/jira_connection_test.rb
git commit -m "Add Jira connection settings (routes, controller, form)"
```

---

### Task 6: `JiraImportsController`

**Files:**
- Create: `app/controllers/jira_imports_controller.rb`
- Test: `test/integration/jira_import_test.rb`

- [ ] **Step 1: Write the failing test**

`test/integration/jira_import_test.rb`:
```ruby
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/integration/jira_import_test.rb`
Expected: FAIL — uninitialized constant `JiraImportsController`.

- [ ] **Step 3: Write the controller**

`app/controllers/jira_imports_controller.rb`:
```ruby
# Imports an Atlassian Jira ticket (by pasted URL) into this project's board.
# Delegates the work to Jira::Importer and turns Jira::Error into a friendly
# board flash. Lands the item in the project the request is scoped to.
class JiraImportsController < ApplicationController
  before_action :set_project

  def create
    unless JiraConnection.configured?
      return redirect_to board_path(@project),
        alert: "Connect Jira first — set your site, email and API token in Jira settings."
    end

    result = Jira::Importer.import(url: params[:url], project: @project)
    verb = result.created ? "Imported" : "Updated"
    att  = result.attachments_added.positive? ? " (#{result.attachments_added} attachment#{'s' if result.attachments_added != 1})" : ""
    redirect_to board_path(@project), notice: "#{verb} #{result.task.external_ref} — “#{result.task.title}”#{att}."
  rescue Jira::Error => e
    redirect_to board_path(@project), alert: e.user_message
  end

  private

  def set_project
    @project = Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/integration/jira_import_test.rb`
Expected: PASS (3 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add app/controllers/jira_imports_controller.rb test/integration/jira_import_test.rb
git commit -m "Add JiraImportsController (URL → board item)"
```

---

### Task 7: Board UI — import button + modal

**Files:**
- Create: `app/javascript/controllers/jira_import_controller.js`
- Create: `app/views/boards/_jira_import.html.erb`
- Modify: `app/views/boards/show.html.erb` (header right cluster)

- [ ] **Step 1: Write the Stimulus controller**

`app/javascript/controllers/jira_import_controller.js`:
```javascript
import { Controller } from "@hotwired/stimulus"

// Toggles the "Import from Jira" modal overlay. Mirrors item_form_controller's
// open/close/backdrop handling (no server round-trip to open).
export default class extends Controller {
  static targets = ["overlay"]

  connect() {
    this.onKey = (e) => { if (e.key === "Escape") this.close() }
    document.addEventListener("keydown", this.onKey)
  }

  disconnect() { document.removeEventListener("keydown", this.onKey) }

  open() { this.overlayTarget.classList.remove("hidden") }

  close(e) {
    if (e) e.preventDefault()
    this.overlayTarget.classList.add("hidden")
  }

  backdrop(e) { if (e.target === e.currentTarget) this.close(e) }
}
```

- [ ] **Step 2: Write the partial**

`app/views/boards/_jira_import.html.erb`:
```erb
<%# "Import from Jira": a header button that reveals a modal with a single URL
    field. Posts to JiraImportsController#create and redirects back to the board. %>
<div data-controller="jira-import" class="inline-block">
  <button type="button" data-action="jira-import#open"
          class="pill pill-quiet cursor-pointer inline-flex items-center gap-1.5">
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="M7 10l5 5 5-5"/><path d="M12 15V3"/></svg>
    Import from Jira
  </button>

  <div data-jira-import-target="overlay"
       class="hidden fixed inset-0 z-50 flex items-start justify-center p-4 sm:p-6 overflow-y-auto"
       style="background: rgba(26,24,20,0.55)"
       data-action="click->jira-import#backdrop">
    <div role="dialog" aria-modal="true" aria-labelledby="jira-import-heading"
         class="paper w-full max-w-lg mt-12" style="box-shadow: 0 24px 60px -20px rgba(26,24,20,0.5)">
      <header class="flex items-center justify-between px-5 py-3 hair-b">
        <div class="min-w-0">
          <div class="eyebrow">Import from Jira</div>
          <div id="jira-import-heading" class="text-sm font-medium">Paste a Jira ticket URL</div>
        </div>
        <button type="button" data-action="jira-import#close" aria-label="Close"
                class="text-[color:var(--color-ink-faint)] hover:text-[color:var(--color-ink)] text-lg leading-none px-1">✕</button>
      </header>

      <%= form_with url: project_jira_imports_path(project), method: :post, class: "p-5 space-y-4" do |f| %>
        <label class="block">
          <span class="eyebrow block mb-1">Ticket URL</span>
          <%= url_field_tag :url, nil, required: true,
                placeholder: "https://your-site.atlassian.net/browse/PROJ-123",
                class: "w-full hair-all rounded px-3 py-2 text-sm bg-[color:var(--color-paper-raised)] focus:border-[color:var(--color-amber-ink)] outline-none" %>
        </label>

        <% unless JiraConnection.configured? %>
          <p class="text-[11px] text-[color:var(--color-ink-faint)]">
            Jira isn’t connected — <%= link_to "set it up", edit_jira_connection_path, class: "text-[color:var(--color-amber-ink)] underline" %> first.
          </p>
        <% end %>

        <div class="flex items-center justify-between gap-2 pt-1">
          <%= link_to "Jira settings", edit_jira_connection_path, class: "text-[11px] text-[color:var(--color-ink-faint)] hover:text-[color:var(--color-amber-ink)]" %>
          <div class="flex items-center gap-2">
            <button type="button" data-action="jira-import#close" class="pill pill-quiet cursor-pointer">Cancel</button>
            <%= f.submit "Import", data: { turbo_submits_with: "Importing…" }, class: "pill pill-accent cursor-pointer" %>
          </div>
        </div>
      <% end %>
    </div>
  </div>
</div>
```

- [ ] **Step 3: Render it in the board header**

In `app/views/boards/show.html.erb`, find the header right cluster:
```erb
  <div class="flex items-center gap-3 shrink-0">
    <div class="flex hair-all rounded-md overflow-hidden text-xs">
```
Insert the partial as the first child of that `div`, before the Table/Kanban toggle:
```erb
  <div class="flex items-center gap-3 shrink-0">
    <%= render "boards/jira_import", project: @project %>
    <div class="flex hair-all rounded-md overflow-hidden text-xs">
```

- [ ] **Step 4: Rebuild Tailwind (in case any class is new to the build) and boot-check**

Run:
```bash
bin/rails tailwindcss:build 2>/dev/null || true
bin/rails runner 'puts "boot ok"'
```
Expected: `boot ok`. (All classes used already appear in existing views, so the build should be a no-op; this just guards the Tailwind staleness gotcha.)

- [ ] **Step 5: Run the full test suite**

Run: `bin/rails test`
Expected: all green (existing board/autopilot/theme tests + the new ones).

- [ ] **Step 6: Commit**

```bash
git add app/javascript/controllers/jira_import_controller.js app/views/boards/_jira_import.html.erb app/views/boards/show.html.erb
git commit -m "Add Import-from-Jira button + modal to the board header"
```

---

### Task 8: Manual verification + wrap-up

**Files:** none (verification only).

- [ ] **Step 1: Lint**

Run: `bin/rubocop app/models/jira_connection.rb app/services/jira app/controllers/jira_imports_controller.rb app/controllers/jira_connections_controller.rb`
Expected: no offenses (fix any per house style before continuing).

- [ ] **Step 2: Manual smoke test (real Jira)**

1. Start the app (the pyr-docker myjira container / `bin/dev`), open a project board at `http://localhost:1200`.
2. Click **Import from Jira** → **set it up** → enter site URL, your Atlassian email, and a real API token → Save.
3. Back on the board, click **Import from Jira**, paste a real ticket URL you can access, Import.
4. Confirm: a new `pending` item appears with the Jira summary as title, correct type/priority, description containing the ticket body (and comments under a "Comments" heading), and any attachments visible on the item page.
5. Import the **same** URL again → confirm no duplicate, fields refreshed, attachments not re-added.
6. Try a bad URL and a ticket you can't access → confirm friendly alerts, nothing created.

- [ ] **Step 3: Update memory**

Add a memory file `myjira_jira_import.md` describing the feature (JiraConnection singleton + encrypted token, `Jira::Client`/`AdfConverter`/`Importer`, dedupe on `external_ref`, board-header modal) and add its one-line pointer to `MEMORY.md`.

- [ ] **Step 4: Final review + PR**

Run: `git log --oneline main..jira-import` to review the commit series, then open a PR with `gh pr create` summarizing the feature and linking the spec.

---

## Self-Review notes

- **Spec coverage:** connection (Task 1/5), REST client + auth + errors (Task 2), ADF→Markdown (Task 3), field/type/priority mapping + comments + attachment dedupe + idempotency + host guard (Task 4), settings form with blank-token preservation (Task 5), import controller with all error branches (Task 6), board-header modal UI (Task 7), full import flow + dedupe + error cases verified (Task 8). Encrypted token (Task 1, verified by the plaintext-column assertion). Status mapping intentionally omitted per spec (items start `pending`).
- **Idempotency contract:** dedupe key is `tasks.external_ref` (already indexed); attachments dedupe by `filename` + `byte_size`. `board_state` preserved on re-import (asserted in Task 4).
- **Names are consistent across tasks:** `JiraConnection#complete?` / `.configured?` / `#host` / `#auth_header` / `#api_base`; `Jira::Client#fetch_issue`/`#download_attachment`; `Jira::AdfConverter.to_markdown`; `Jira::Importer.import` → `Result(task, created, attachments_added, attachments_skipped)`; `Jira::Error#kind`/`#user_message`.
- **No new gems:** HTTP stubbed via Minitest's built-in `Object#stub` + injected `FakeClient`.
