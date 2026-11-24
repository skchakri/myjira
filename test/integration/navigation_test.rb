require "test_helper"

# Sidebar trim (five primary links + a "More" group), the cross-project Documents
# list, folded empty sections on a project page, and stale relay tickets.
class NavigationTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Nav Test", slug: "nav-#{SecureRandom.hex(3)}",
                               repo_path: "/tmp/nav-test-#{SecureRandom.hex(3)}")
  end

  test "sidebar shows the primary links in order and folds the rest under More" do
    get documents_path
    assert_response :success
    labels = css_select("#app-sidebar nav[aria-label='Main'] a.clink span.truncate:not(.clink-slug)").map { |n| n.text.strip }
    assert_equal ["Inbox", "Work Queue", "Conversations", "Documents", "Relay", "Calendar"], labels
    assert_select "#app-sidebar nav[aria-label='Main'] a.clink-active span.truncate:not(.clink-slug)", text: "Documents"

    assert_select "#app-sidebar details#sidebar_more[data-controller='disclosure']" do
      assert_select "a.clink[href='#{review_path}']"
      assert_select "a.clink[href='#{approvals_path}']"
      assert_select "a.clink[href='#{projects_path}']"
      assert_select "nav[aria-label='Projects']"
    end
    assert_select "#app-sidebar details#sidebar_more[open]", 0
    assert_select "#app-sidebar details#sidebar_more[data-disclosure-force-value='false']"
  end

  test "More opens by itself on a page that lives inside it" do
    get review_path
    assert_response :success
    assert_select "#app-sidebar details#sidebar_more[open][data-disclosure-force-value='true']"
    assert_select "#app-sidebar details#sidebar_more a.clink-active[href='#{review_path}']"
  end

  test "documents index lists every project's documents newest first, filterable and paged" do
    other = Project.create!(name: "Nav Other", slug: "nav-o-#{SecureRandom.hex(3)}", repo_path: "/tmp/nav-o-#{SecureRandom.hex(3)}")
    old = @project.documents.create!(title: "Old plan", kind: "plan", body: "x", author: "cli")
    old.update_columns(updated_at: 2.days.ago)
    other.documents.create!(title: "Fresh report", kind: "report", body: "y", author: "cli")

    get documents_path
    assert_response :success
    titles = css_select("#document_library li a.block").map { |n| n.text.strip }
    assert_operator titles.index("Fresh report"), :<, titles.index("Old plan")
    assert_select "#document_library a[href='#{project_document_path(@project, old)}']"

    get documents_path(project: @project.slug)
    assert_select "#document_library li", 1
    assert_select "#document_library li a.block", text: "Old plan"

    get documents_path(project: other.slug, kind: "plan")
    assert_select "#document_library", 0

    (DocumentLibraryController::PER_PAGE + 1).times { |i| @project.documents.create!(title: "Note #{i}", kind: "note", body: "n", author: "cli") }
    get documents_path(project: @project.slug)
    assert_select "#document_library li", DocumentLibraryController::PER_PAGE
    assert_select "a[rel='next']"
    get documents_path(project: @project.slug, page: 2)
    assert_select "#document_library li", 2
    assert_select "a[rel='prev']"
    assert_select "a[rel='next']", 0
  end

  test "project page folds empty sections behind More and keeps filled ones visible" do
    get project_path(@project)
    assert_response :success
    assert_select "details#project_more" do
      assert_select "section.paper header .eyebrow", text: "Test plans"
      assert_select "section.paper header .eyebrow", text: "Open follow-ups"
      assert_select "a[href='#{new_project_test_plan_path(@project)}']"
      assert_select "a[href='#{project_playbooks_path(@project)}']"
    end

    @project.test_plans.create!(title: "Smoke")
    get project_path(@project)
    assert_select "details#project_more section.paper header .eyebrow", text: "Test plans", count: 0
    assert_select "section.paper header .eyebrow", text: "Test plans"
  end

  test "stale relay tickets are hidden by default, marked and sorted last when shown" do
    live = @project.browser_tasks.create!(title: "Live one", status: "queued")
    stale = @project.browser_tasks.create!(title: "Stale one", status: "in_progress")
    stale.update_columns(last_activity_at: 3.days.ago, updated_at: 3.days.ago)
    done = @project.browser_tasks.create!(title: "Old done", status: "done")
    done.update_columns(last_activity_at: 5.days.ago, updated_at: 5.days.ago)

    assert stale.reload.stale?
    assert_not live.stale?
    assert_not done.reload.stale?
    assert_equal [stale.id], @project.browser_tasks.stale.pluck(:id)
    assert_equal [live.id, done.id].sort, @project.browser_tasks.fresh.pluck(:id).sort

    get project_browser_tasks_path(@project)
    assert_response :success
    assert_select "#relay_stale_bar", text: /1 ticket/
    assert_select "tr[data-stale='true']", 0
    assert_select "a", text: "Show stale"
    assert_select "form[action='#{cancel_stale_browser_tasks_path(project_id: @project.slug)}']"

    get project_browser_tasks_path(@project, stale: "show")
    rows = css_select("tbody tr").map { |tr| tr.at_css("a").text.strip }
    assert_equal "Stale one", rows.last
    assert_select "tr[data-stale='true'] .relay-stale-tag", text: "stale"
  end

  test "cancel stale cancels only stale tickets of that project and deletes nothing" do
    live = @project.browser_tasks.create!(title: "Live one", status: "dispatched")
    stale = @project.browser_tasks.create!(title: "Stale one", status: "needs_input")
    stale.update_columns(last_activity_at: 2.days.ago, updated_at: 2.days.ago)
    other = Project.create!(name: "Nav Other", slug: "nav-o-#{SecureRandom.hex(3)}", repo_path: "/tmp/nav-o-#{SecureRandom.hex(3)}")
    elsewhere = other.browser_tasks.create!(title: "Elsewhere", status: "queued")
    elsewhere.update_columns(last_activity_at: 2.days.ago, updated_at: 2.days.ago)

    assert_no_difference -> { BrowserTask.count } do
      post cancel_stale_browser_tasks_path(project_id: @project.slug)
    end
    assert_redirected_to project_browser_tasks_path(@project.slug)
    assert_equal "cancelled", stale.reload.status
    assert_match(/stale/, stale.browser_messages.last.body)
    assert_equal "dispatched", live.reload.status
    assert_equal "queued", elsewhere.reload.status
  end
end
