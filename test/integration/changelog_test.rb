require "test_helper"

# The per-project "What's New" changelog page + the blurb-authoring round-trip.
class ChangelogTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Changelog Test", slug: "changelog-#{SecureRandom.hex(3)}",
                               repo_path: "/tmp/changelog-test")
  end

  test "lists shipped items that carry a blurb, with the humanized title and blurb" do
    @project.tasks.create!(title: "[user-req] Dark mode", item_type: "feature", board_state: "done",
                           changelog_summary: "You can now switch the app to dark mode.", finished_at: 1.hour.ago)

    get project_changelog_path(@project)
    assert_response :success
    assert_select "h2", text: /Dark mode/
    assert_select "h2", text: /\[user-req\]/, count: 0
    assert_match "You can now switch the app to dark mode.", @response.body
  end

  test "excludes done-without-blurb and not-yet-done items" do
    @project.tasks.create!(title: "Silent chore", item_type: "task", board_state: "done")
    @project.tasks.create!(title: "Not shipped", item_type: "feature", board_state: "in_review",
                           changelog_summary: "Has a blurb but not shipped yet.")

    get project_changelog_path(@project)
    assert_response :success
    assert_select "h2", count: 0
    assert_match(/No updates yet/, @response.body)
  end

  test "renders a friendly empty state when there are no entries" do
    get project_changelog_path(@project)
    assert_response :success
    assert_match(/No updates yet/, @response.body)
  end

  test "renders image/video walkthrough media for an entry" do
    t = @project.tasks.create!(title: "With media", item_type: "feature", board_state: "done",
                               changelog_summary: "shipped", finished_at: 1.hour.ago)
    t.attachments.attach(io: StringIO.new("png"), filename: "shot.png", content_type: "image/png")

    get project_changelog_path(@project)
    assert_response :success
    assert_select "img"
  end

  test "PATCH board_item persists a changelog_summary blurb" do
    t = @project.tasks.create!(title: "Item", item_type: "feature", board_state: "done")

    patch board_item_path(@project, t), params: { task: { changelog_summary: "Now humanized." }, return_to: "task" }
    assert_equal "Now humanized.", t.reload.changelog_summary
  end
end
