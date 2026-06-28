require "test_helper"

# McpServer is the read-only mirror of one `claude mcp list` entry, synced by the
# host daemon. It validates the synced shape (known scope/transport, present
# name) and — under the stateless 2026-07-28 spec — that any stored remote URL is
# a real http(s) endpoint, while not rejecting url-less (stdio) rows.
class McpServerTest < ActiveSupport::TestCase
  def server(**overrides)
    McpServer.new({
      name: "ctx7", scope: "user", transport: "stdio", status: "connected"
    }.merge(overrides))
  end

  test "a minimal stdio server row is valid" do
    assert server.valid?
  end

  test "inclusion validations reject unknown scope/transport" do
    assert_not server(scope: "galaxy").valid?
    assert_not server(transport: "carrier-pigeon").valid?
  end

  test "name is required" do
    assert_not server(name: nil).valid?
  end

  test "a remote server with a real http(s) url is valid" do
    assert server(transport: "http", url: "https://mcp.context7.com/mcp").valid?
  end

  test "a remote server with a malformed url is rejected" do
    srv = server(transport: "http", url: "mcp.context7.com/mcp")
    assert_not srv.valid?
    assert_not_empty srv.errors[:url]
  end

  test "url validation only fires when a url is present" do
    # stdio rows carry no url and must not be rejected for it.
    assert server(transport: "stdio", url: nil).valid?
    assert server(transport: "stdio", url: "").valid?
  end

  test "global? is true for user scope and for project-less rows" do
    assert server(scope: "user").global?
    assert server(scope: "project", project_id: nil).global?
  end

  test "endpoint_label shows the command for stdio and the url for remote" do
    assert_equal "npx -y pkg", server(transport: "stdio", command: "npx", args: ["-y", "pkg"]).endpoint_label
    assert_equal "https://x/mcp", server(transport: "http", url: "https://x/mcp").endpoint_label
  end
end
