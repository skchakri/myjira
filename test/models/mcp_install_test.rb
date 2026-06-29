require "test_helper"

# McpInstall is the web-filed intent row the host daemon polls to run
# `claude mcp add/remove`. Its validations are the only guard between a
# UI/API request and a command that reaches the host CLI, so they carry weight:
# a valid name charset, known transport/scope/action/status, and a present,
# well-formed add spec (stdio → command, http/sse → http(s) URL).
class McpInstallTest < ActiveSupport::TestCase
  def add(**overrides)
    McpInstall.new({
      action: "add", name: "ctx7", transport: "stdio", command: "npx",
      scope: "user", status: "pending"
    }.merge(overrides))
  end

  test "a stdio add with a command is valid" do
    assert add.valid?
  end

  test "inclusion validations reject unknown enums" do
    assert_not add(action: "frobnicate").valid?
    assert_not add(scope: "galaxy").valid?
    assert_not add(transport: "carrier-pigeon").valid?
    assert_not add(status: "vibing").valid?
  end

  test "NAME_FORMAT accepts the charset Claude accepts and rejects the rest" do
    assert add(name: "my-server_1.2").valid?
    assert_not add(name: "bad name").valid?, "spaces are rejected"
    assert_not add(name: "rm -rf;").valid?, "shell metacharacters are rejected"
  end

  test "a stdio add without a command is invalid" do
    inst = add(command: nil)
    assert_not inst.valid?
    assert_includes inst.errors[:command], "is required for a stdio server"
  end

  test "an http add requires a url" do
    inst = add(transport: "http", command: nil, url: nil)
    assert_not inst.valid?
    assert_includes inst.errors[:url], "is required for an http server"
  end

  test "an http add requires an http(s) url, not a relative or bare host" do
    inst = add(transport: "http", command: nil, url: "mcp.example.com/mcp")
    assert_not inst.valid?
    assert_includes inst.errors[:url], "must be an http(s) URL for an http server"
  end

  test "http and sse adds accept real http(s) endpoints" do
    assert add(transport: "http", command: nil, url: "https://mcp.context7.com/mcp").valid?
    assert add(transport: "sse",  command: nil, url: "http://localhost:9000/sse").valid?
  end

  test "a remove needs neither a command nor a url" do
    inst = McpInstall.new(action: "remove", name: "ctx7", transport: "http",
                          scope: "user", status: "pending")
    assert inst.valid?
  end

  test "queue_add! persists an add intent with defaulted env" do
    inst = McpInstall.queue_add!(name: "ctx7", transport: "http",
                                 url: "https://mcp.context7.com/mcp")
    assert inst.persisted?
    assert_equal "add", inst.action
    assert_equal({}, inst.env)
  end

  test "env_keys exposes only the names of secret env vars" do
    inst = McpInstall.queue_add!(name: "linear", transport: "http",
                                 url: "https://mcp.linear.app/mcp",
                                 env: { "API_KEY" => "sk-secret" })
    assert_equal ["API_KEY"], inst.env_keys
  end
end
