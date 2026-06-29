require "test_helper"

class Anthropic::MessagesClientTest < ActiveSupport::TestCase
  FakeResp = Struct.new(:code, :body)

  def ok_body
    { "content" => [{ "type" => "text", "text" => '{"agent_role":"engineering"}' }] }.to_json
  end

  test "returns first text content block on 200" do
    c = Anthropic::MessagesClient.new(api_key: "test-key")
    c.stub(:post, FakeResp.new("200", ok_body)) do
      result = c.complete(model: "haiku", max_tokens: 64, user: "hi")
      assert_includes result, "engineering"
    end
  end

  test "raises Anthropic::Error on non-200 response" do
    c = Anthropic::MessagesClient.new(api_key: "test-key")
    c.stub(:post, FakeResp.new("401", "Unauthorized")) do
      assert_raises(Anthropic::Error) { c.complete(model: "haiku", max_tokens: 64, user: "hi") }
    end
  end

  test "raises Anthropic::Error on malformed JSON body" do
    c = Anthropic::MessagesClient.new(api_key: "test-key")
    c.stub(:post, FakeResp.new("200", "not-json")) do
      assert_raises(Anthropic::Error) { c.complete(model: "haiku", max_tokens: 64, user: "hi") }
    end
  end
end
