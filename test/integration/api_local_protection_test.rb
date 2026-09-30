require "test_helper"

# The API executes work (SessionLaunches → unattended Claude sessions), so a
# cross-site browser POST is a drive-by RCE attempt. LocalApiProtection rejects
# those while leaving every header-less CLI caller (daemon, board agents,
# skills, hooks) untouched. These tests pin that boundary.
class ApiLocalProtectionTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Sec", slug: "sec-#{SecureRandom.hex(3)}", repo_path: "/tmp/sec")
  end

  def create_params
    { task: { title: "hello", item_type: "task" } }
  end

  test "a header-less CLI request (curl/daemon) passes" do
    post "/api/v1/projects/#{@project.slug}/tasks", params: create_params, as: :json
    assert_response :created
  end

  test "a cross-site browser POST (foreign Origin) is rejected" do
    assert_no_difference -> { @project.tasks.count } do
      post "/api/v1/projects/#{@project.slug}/tasks", params: create_params, as: :json,
           headers: { "Origin" => "https://evil.example" }
    end
    assert_response :forbidden
  end

  test "Sec-Fetch-Site cross-site is rejected even without an Origin" do
    assert_no_difference -> { @project.tasks.count } do
      post "/api/v1/projects/#{@project.slug}/tasks", params: create_params, as: :json,
           headers: { "Sec-Fetch-Site" => "cross-site" }
    end
    assert_response :forbidden
  end

  test "an 'Origin: null' (sandboxed iframe) request is rejected" do
    post "/api/v1/projects/#{@project.slug}/tasks", params: create_params, as: :json,
         headers: { "Origin" => "null" }
    assert_response :forbidden
  end

  test "a same-origin browser fetch from the app's own UI passes" do
    post "/api/v1/projects/#{@project.slug}/tasks", params: create_params, as: :json,
         headers: { "Origin" => "http://localhost:1200", "Sec-Fetch-Site" => "same-origin" }
    assert_response :created
  end

  test "a 127.0.0.1 origin passes" do
    post "/api/v1/projects/#{@project.slug}/tasks", params: create_params, as: :json,
         headers: { "Origin" => "http://127.0.0.1:1200" }
    assert_response :created
  end

  test "a valid bearer token overrides the origin check" do
    ENV["MYJIRA_API_TOKEN"] = "sekret-token"
    post "/api/v1/projects/#{@project.slug}/tasks", params: create_params, as: :json,
         headers: { "Origin" => "https://evil.example", "Authorization" => "Bearer sekret-token" }
    assert_response :created
  ensure
    ENV.delete("MYJIRA_API_TOKEN")
  end

  test "a wrong bearer token does not override the origin check" do
    ENV["MYJIRA_API_TOKEN"] = "sekret-token"
    post "/api/v1/projects/#{@project.slug}/tasks", params: create_params, as: :json,
         headers: { "Origin" => "https://evil.example", "Authorization" => "Bearer wrong" }
    assert_response :forbidden
  ensure
    ENV.delete("MYJIRA_API_TOKEN")
  end

  test "GET reads are also protected from cross-site pages" do
    get "/api/v1/projects/#{@project.slug}/tasks", headers: { "Origin" => "https://evil.example" }
    assert_response :forbidden
  end
end
