require "test_helper"

# The JSON/multipart media-ingestion endpoint the relay (CLI ⇄ Claude-in-Chrome)
# calls to attach screenshots / GIFs captured during a real browser test run to
# an existing board item.
class TaskAttachmentsTest < ActionDispatch::IntegrationTest
  # 1×1 transparent PNG.
  PNG_BASE64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==".freeze

  setup do
    @project = Project.create!(name: "Attach Test", slug: "attach-#{SecureRandom.hex(3)}",
                               repo_path: "/tmp/attach-test")
    @task = @project.tasks.create!(title: "Capture media", item_type: "feature", board_state: "in_review")
  end

  def attach_url
    "/api/v1/projects/#{@project.slug}/tasks/#{@task.id}/attachments"
  end

  test "attaches a base64 screenshot to the task" do
    post attach_url,
         params: { attachments: [{ filename: "shot.png", content_type: "image/png", data_base64: PNG_BASE64 }] },
         as: :json
    assert_response :created
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_equal 1, body["attached"].size
    assert_equal "image/png", body["attached"].first["content_type"]
    assert @task.reload.attachments.attached?
    assert_equal "image/png", @task.attachments.first.content_type
  end

  test "tolerates a data: URI prefix and infers content_type from filename" do
    post attach_url,
         params: { attachments: [{ filename: "run.png", data_base64: "data:image/png;base64,#{PNG_BASE64}" }] },
         as: :json
    assert_response :created
    assert_equal "image/png", @task.reload.attachments.first.content_type
  end

  test "accepts a multipart file upload" do
    file = Rack::Test::UploadedFile.new(
      StringIO.new(Base64.decode64(PNG_BASE64)), "image/png", original_filename: "ss.png"
    )
    post attach_url, params: { attachments: [file] }
    assert_response :created
    assert @task.reload.attachments.attached?
  end

  test "reports invalid base64 as rejected without attaching" do
    post attach_url,
         params: { attachments: [{ filename: "bad.png", content_type: "image/png", data_base64: "" }] },
         as: :json
    assert_response :unprocessable_entity
    assert_not @task.reload.attachments.attached?
  end

  test "rejects when the count limit is exceeded" do
    over = (Task::MAX_ATTACHMENTS + 1).times.map do |i|
      { filename: "s#{i}.png", content_type: "image/png", data_base64: PNG_BASE64 }
    end
    post attach_url, params: { attachments: over }, as: :json
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "invalid", body["error"]
    assert_not @task.reload.attachments.attached?, "nothing persists when validation fails"
  end

  test "404 for an unknown task" do
    post "/api/v1/projects/#{@project.slug}/tasks/#{SecureRandom.uuid}/attachments",
         params: { attachments: [{ filename: "s.png", data_base64: PNG_BASE64 }] }, as: :json
    assert_response :not_found
  end
end
