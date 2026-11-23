require "test_helper"

class ConversationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    project = Project.create!(name: "Docs", slug: "docs-#{SecureRandom.hex(3)}", repo_path: "/tmp/docs")
    @convo = project.conversations.create!(session_id: SecureRandom.uuid)
  end

  def record_write(path)
    @convo.conversation_messages.create!(
      ext_id: SecureRandom.uuid, role: "assistant", kind: "tool",
      payload: { "tool" => "Write", "input" => { "file_path" => path } },
      position: (@convo.conversation_messages.maximum(:position) || -1) + 1, occurred_at: Time.current
    )
  end

  test "serves a recorded document under an allowed root" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "notes.md")
      File.write(path, "# Hello doc")
      record_write(path)
      get document_conversation_path(@convo, path: path)
      assert_response :success
      assert_includes response.body, "Hello doc"
    end
  end

  test "refuses a recorded document outside the allowed roots" do
    record_write("/etc/passwd.md")
    get document_conversation_path(@convo, path: "/etc/passwd.md")
    assert_redirected_to conversation_path(@convo)
  end

  test "refuses a symlink that escapes the allowed roots" do
    Dir.mktmpdir do |dir|
      link = File.join(dir, "escape.txt")
      File.symlink("/etc/hostname", link)
      record_write(link)
      get document_conversation_path(@convo, path: link)
      assert_redirected_to conversation_path(@convo)
    end
  end

  test "refuses a path that was never recorded" do
    get document_conversation_path(@convo, path: "/tmp/never.md")
    assert_redirected_to conversation_path(@convo)
  end
end
