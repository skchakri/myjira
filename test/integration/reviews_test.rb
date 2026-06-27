require "test_helper"

# The global /review queue: every in_review board item across all active
# projects, grouped by project, with the board's Approve & merge / Reject
# actions. Covers grouping, the in_review filter, archived exclusion, and the
# empty state.
class ReviewsTest < ActionDispatch::IntegrationTest
  setup do
    @alpha = Project.create!(name: "Alpha", slug: "alpha-#{SecureRandom.hex(3)}", repo_path: "/tmp/alpha")
    @beta  = Project.create!(name: "Beta",  slug: "beta-#{SecureRandom.hex(3)}",  repo_path: "/tmp/beta")
  end

  test "lists in_review items grouped under their project headers" do
    a = @alpha.tasks.create!(title: "Alpha awaiting review", board_state: "in_review",
                             pr_url: "https://example.com/pr/1", pr_number: 1, pr_state: "open")
    b = @beta.tasks.create!(title: "Beta awaiting review", board_state: "in_review",
                            pr_url: "https://example.com/pr/2", pr_number: 2, pr_state: "open")

    get review_path
    assert_response :success
    assert_match a.title, response.body
    assert_match b.title, response.body
    # Both project headers (links to each board) are present → grouping works.
    assert_select "a[href=?]", board_path(@alpha)
    assert_select "a[href=?]", board_path(@beta)
  end

  test "excludes items not in review" do
    shown  = @alpha.tasks.create!(title: "Visible review item", board_state: "in_review")
    hidden = @alpha.tasks.create!(title: "Still planned item", board_state: "planned")

    get review_path
    assert_response :success
    assert_match shown.title, response.body
    refute_match hidden.title, response.body
  end

  test "excludes items from archived projects" do
    visible = @alpha.tasks.create!(title: "Active project review", board_state: "in_review")
    @beta.archive!
    archived = @beta.tasks.create!(title: "Archived project review", board_state: "in_review")

    get review_path
    assert_response :success
    assert_match visible.title, response.body
    refute_match archived.title, response.body
  end

  test "renders the empty state when nothing is awaiting review" do
    get review_path
    assert_response :success
    assert_match "Nothing awaiting review", response.body
  end
end
