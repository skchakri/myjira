require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  test "clients scope includes a project that has work but is not listed" do
    p = Project.create!(name: "Worked", slug: "worked-proj", repo_path: "/tmp/worked")
    p.tasks.create!(title: "do thing")
    assert_includes Project.clients, p
  end

  test "clients scope includes a listed project with no work" do
    p = Project.create!(name: "Pinned", slug: "pinned-proj", repo_path: "/tmp/pinned", listed: true)
    assert_includes Project.clients, p
  end

  test "clients scope excludes an unlisted project with no work" do
    p = Project.create!(name: "Quiet", slug: "quiet-proj", repo_path: "/tmp/quiet")
    refute_includes Project.clients, p
  end

  test "active and archived scopes partition projects by archived_at" do
    live = Project.create!(name: "Live", slug: "live-proj", repo_path: "/tmp/live", listed: true)
    gone = Project.create!(name: "Gone", slug: "gone-proj", repo_path: "/tmp/gone", listed: true)
    gone.archive!

    assert_includes Project.active, live
    refute_includes Project.active, gone
    assert_includes Project.archived, gone
    refute_includes Project.archived, live
  end

  test "clients.active excludes an archived project even when listed" do
    p = Project.create!(name: "Pinned but gone", slug: "pinned-gone", repo_path: "/tmp/pg", listed: true)
    assert_includes Project.clients.active, p
    p.archive!
    refute_includes Project.clients.active, p
    assert_includes Project.clients.archived, p
  end

  test "archive! and unarchive! flip archived_at and archived?" do
    p = Project.create!(name: "Toggle", slug: "toggle-proj", repo_path: "/tmp/toggle")
    refute_predicate p, :archived?

    p.archive!
    assert_predicate p, :archived?
    assert_not_nil p.archived_at

    p.unarchive!
    refute_predicate p, :archived?
    assert_nil p.archived_at
  end
end
