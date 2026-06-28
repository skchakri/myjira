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

  test "next_board_item picks the highest-severity, oldest actionable item, ignoring display position" do
    p = Project.create!(name: "Queue", slug: "queue-proj", repo_path: "/tmp/queue")
    # A newer, display-pinned normal item must NOT jump the queue ahead of an urgent one.
    urgent = p.tasks.create!(title: "Urgent", item_type: "task", board_state: "pending",
                             priority: "urgent", created_at: 1.hour.ago)
    normal = p.tasks.create!(title: "Normal pinned", item_type: "task", board_state: "pending",
                             priority: "normal", created_at: 1.minute.ago)
    normal.update_column(:position, 1) # dragged to top of the display

    assert_equal urgent.id, p.next_board_item.id,
                 "the work queue follows severity/FIFO, not the dragged display order"
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

  # --- memory_block ----------------------------------------------------------
  test "memory_block is nil when there is no preamble and no facts" do
    p = Project.create!(name: "Empty", slug: "empty-mem", repo_path: "/tmp/empty-mem")
    assert_nil p.memory_block
  end

  test "memory_block includes the preamble and the learned facts" do
    p = Project.create!(name: "Mem", slug: "mem-block", repo_path: "/tmp/mem-block",
                        memory_preamble: "Lint with bin/rubocop.")
    KnowledgeFact.record!(project: p, body: "tests in test/ with Minitest")
    block = p.memory_block
    assert_includes block, "Project memory — Mem"
    assert_includes block, "Lint with bin/rubocop."
    assert_includes block, "- tests in test/ with Minitest"
  end

  test "memory_block caps facts at MEMORY_FACT_LIMIT, most recent first" do
    p = Project.create!(name: "Cap", slug: "cap-mem", repo_path: "/tmp/cap-mem")
    base = Time.current
    (Project::MEMORY_FACT_LIMIT + 3).times do |i|
      KnowledgeFact.record!(project: p, body: "fact #{i}")
      p.knowledge_facts.find_by(fingerprint: KnowledgeFact.fingerprint("fact #{i}"))
       .update_column(:last_seen_at, base + i.seconds)
    end
    lines = p.memory_block.scan(/^- /).length
    assert_equal Project::MEMORY_FACT_LIMIT, lines
  end
end
