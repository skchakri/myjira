require "test_helper"

class LiveSessionsApiTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Live", slug: "live-#{SecureRandom.hex(3)}", repo_path: "/tmp/live")
    @live = @project.conversations.create!(session_id: SecureRandom.uuid, name: "worker",
                                           started_at: 1.hour.ago, last_message_at: 1.minute.ago)
    @live.conversation_messages.create!(role: "user", kind: "message", body: "hello", position: 0, ext_id: "m1",
                                        occurred_at: 1.minute.ago)
    @old = @project.conversations.create!(session_id: SecureRandom.uuid, started_at: 2.days.ago,
                                          last_message_at: 2.days.ago)
  end

  test "lists only live sessions with messages and listener state" do
    get "/api/v1/sessions/live", as: :json
    assert_response :ok
    ids = response.parsed_body["sessions"].map { _1["session_id"] }
    assert_includes ids, @live.session_id
    assert_not_includes ids, @old.session_id

    row = response.parsed_body["sessions"].find { _1["session_id"] == @live.session_id }
    assert_equal "worker", row["name"]
    assert_equal "/tmp/live", row["repo_path"]
    assert_equal false, row["listening"]
    assert_equal [ "hello" ], row["messages"].map { _1["body"] }
  end

  test "polling the command inbox marks the session as listening" do
    get "/api/v1/sessions/#{@live.session_id}/commands", as: :json
    assert_response :ok
    assert @live.reload.listening?
  end

  test "a command can be queued over the API" do
    post "/api/v1/sessions/#{@live.session_id}/commands", params: { body: "run tests", source: "homey" }, as: :json
    assert_response :created
    cmd = @live.session_commands.last
    assert_equal "run tests", cmd.body
    assert_equal "homey", cmd.source
    assert_equal "pending", cmd.status
  end

  test "a blank command is rejected and an unknown session is 404" do
    post "/api/v1/sessions/#{@live.session_id}/commands", params: { body: " " }, as: :json
    assert_response :unprocessable_entity
    post "/api/v1/sessions/nope/commands", params: { body: "x" }, as: :json
    assert_response :not_found
  end

  test "a command can carry files over multipart" do
    png = Rack::Test::UploadedFile.new(StringIO.new("\x89PNG\r\n\x1a\nfake"), "image/png", true, original_filename: "shot.png")
    pdf = Rack::Test::UploadedFile.new(StringIO.new("%PDF-1.4 fake"), "application/pdf", true, original_filename: "spec.pdf")
    post "/api/v1/sessions/#{@live.session_id}/commands", params: { source: "homey", files: [ png, pdf ] }
    assert_response :created
    cmd = @live.session_commands.last
    assert_equal "Review the attached file(s).", cmd.body
    assert_equal %w[shot.png spec.pdf], cmd.files.map { _1.filename.to_s }.sort
    assert_equal 2, response.parsed_body["attachments"].size
  end

  test "a disallowed file type is rejected" do
    exe = Rack::Test::UploadedFile.new(StringIO.new("MZ"), "application/x-msdownload", true, original_filename: "x.exe")
    post "/api/v1/sessions/#{@live.session_id}/commands", params: { body: "run", files: [ exe ] }
    assert_response :unprocessable_entity
  end
end
