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
end
