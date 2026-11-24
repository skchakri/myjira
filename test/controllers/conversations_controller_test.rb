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

  test "the grouped hub pages folders and loads agent pills lazily" do
    stamp = 1.minute.from_now
    (ConversationsController::GROUPS_PER_PAGE + 1).times do |i|
      p = Project.create!(name: "Paged #{i}", slug: "paged-#{i}-#{SecureRandom.hex(3)}", repo_path: "/tmp/paged#{i}")
      p.conversations.create!(session_id: SecureRandom.uuid, title: "Session #{i}", last_message_at: stamp + i.seconds)
    end
    Agent.create!(name: "helper", kind: "agent", scope: "global", enabled: true) if Agent.enabled.where(scope: "global").none?

    get conversations_path
    assert_response :success
    assert_select "section.conv-group", ConversationsController::GROUPS_PER_PAGE
    assert_select "section.conv-group", text: /Paged #{ConversationsController::GROUPS_PER_PAGE}/
    assert_select "turbo-frame#conv_more_2[loading=lazy][src*='page=2']"
    assert_select "turbo-frame[id^=agents_strip_][loading=lazy]"
    assert_select "form[action*='/agents/']", 0

    get conversations_path(page: 2)
    assert_response :success
    assert_select "turbo-frame#conv_more_2 section.conv-group", minimum: 1
    assert_select "turbo-frame#conv_more_2", text: /Paged 0/
    assert_select "nav", 0
  end

  test "the flat view keeps its filter across pages" do
    project = @convo.project
    ConversationsController::PER_PAGE.times { |i| project.conversations.create!(session_id: SecureRandom.uuid, title: "Flat #{i}", last_message_at: 1.hour.from_now + i.seconds) }

    get conversations_path(view: "flat")
    assert_response :success
    assert_select ".conv-card", ConversationsController::PER_PAGE
    assert_select "turbo-frame#conv_more_2[src*='view=flat'][src*='page=2']"

    get conversations_path(view: "flat", page: 2)
    assert_select "turbo-frame#conv_more_2 .conv-card", minimum: 1
  end

  test "a project's sessions page inside that project" do
    project = @convo.project
    ConversationsController::PER_PAGE.times { |i| project.conversations.create!(session_id: SecureRandom.uuid, title: "Mine #{i}", last_message_at: 1.hour.from_now + i.seconds) }

    get project_conversations_path(project)
    assert_select ".conv-card", ConversationsController::PER_PAGE
    assert_select "turbo-frame#conv_more_2[src^='/projects/#{project.slug}/conversations'][src*='page=2']"

    get project_conversations_path(project, page: 2)
    assert_select "turbo-frame#conv_more_2 .conv-card", 1
  end

  test "a folder's agent pills load from its own endpoint" do
    get project_agents_path(@convo.project)
    assert_response :success
    assert_select "turbo-frame#agents_strip_#{@convo.project.id}"
  end
end
