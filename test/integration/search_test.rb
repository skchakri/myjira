require "test_helper"

# The global /search endpoint: grouped, deep-linked results across the four
# searchable models, optional project scoping, and the blank/no-result states.
class SearchTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Alpha", slug: "alpha-#{SecureRandom.hex(3)}", repo_path: "/tmp/alpha")
    @other   = Project.create!(name: "Beta",  slug: "beta-#{SecureRandom.hex(3)}",  repo_path: "/tmp/beta")
    @task = @project.tasks.create!(title: "Searchable kangaroo feature", description: "build the marsupial view")
  end

  test "blank query renders the empty prompt and runs no search" do
    get search_path
    assert_response :success
    assert_match "Type a query to search", response.body
    refute_match @task.title, response.body
  end

  test "a matching query returns the item with a deep link" do
    get search_path(q: "kangaroo")
    assert_response :success
    assert_match @task.title, response.body
    assert_select "a[href=?]", project_task_path(@project, @task)
  end

  test "no matches renders the no-results state" do
    get search_path(q: "thismatchesnothingxyz")
    assert_response :success
    assert_match "No matches", response.body
  end

  test "project_id scopes results to that folder" do
    other_task = @other.tasks.create!(title: "Searchable kangaroo elsewhere")

    get search_path(q: "kangaroo", project_id: @project.slug)
    assert_response :success
    assert_match @task.title, response.body
    refute_match other_task.title, response.body, "scoped search excludes other projects"
  end

  test "project_id also accepts a uuid" do
    get search_path(q: "kangaroo", project_id: @project.id)
    assert_response :success
    assert_match @task.title, response.body
  end

  test "an unknown project scope 404s" do
    get search_path(q: "kangaroo", project_id: "no-such-project")
    assert_response :not_found
  end

  test "conversation messages and their turn anchors are searchable" do
    convo = @project.conversations.create!(session_id: "sess-#{SecureRandom.hex(4)}")
    msg = convo.conversation_messages.create!(ext_id: "x1", role: "user", body: "platypus deployment notes")

    get search_path(q: "platypus")
    assert_response :success
    assert_select "a[href=?]", conversation_path(convo, anchor: "conversation_message_#{msg.id}")
  end
end
