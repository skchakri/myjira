require "test_helper"

# Per-project learned codebase facts: deduped on a normalized fingerprint
# (re-seeing bumps recency/count, never dupes) and capped at MAX_FACTS by
# recency so facts that stop reappearing retire on their own.
class KnowledgeFactTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "KF", slug: "kf-#{SecureRandom.hex(3)}", repo_path: "/tmp/kf")
  end

  test "fingerprint normalizes case and whitespace" do
    assert_equal "auth lives in app/auth", KnowledgeFact.fingerprint("  Auth  lives   in App/auth ")
    assert_equal KnowledgeFact.fingerprint("UUID primary keys"),
      KnowledgeFact.fingerprint("uuid   primary  keys")
  end

  test "record! creates a fact" do
    fact = KnowledgeFact.record!(project: @project, body: "auth lives in app/services/auth")
    assert fact.persisted?
    assert_equal 1, fact.times_seen
    assert_not_nil fact.last_seen_at
    assert_equal 1, @project.knowledge_facts.count
  end

  test "record! dedupes on fingerprint and bumps times_seen instead of duplicating" do
    KnowledgeFact.record!(project: @project, body: "UUID primary keys everywhere")
    fact = KnowledgeFact.record!(project: @project, body: "uuid   PRIMARY keys everywhere")
    assert_equal 1, @project.knowledge_facts.count, "same fingerprint must not create a second row"
    assert_equal 2, fact.times_seen
  end

  test "record! keeps facts scoped per project" do
    other = Project.create!(name: "KF2", slug: "kf2-#{SecureRandom.hex(3)}", repo_path: "/tmp/kf2")
    KnowledgeFact.record!(project: @project, body: "shared body")
    KnowledgeFact.record!(project: other, body: "shared body")
    assert_equal 1, @project.knowledge_facts.count
    assert_equal 1, other.knowledge_facts.count
  end

  test "record! rejects blank and over-long bodies" do
    assert_nil KnowledgeFact.record!(project: @project, body: "   ")
    assert_nil KnowledgeFact.record!(project: @project, body: "x" * (KnowledgeFact::MAX_BODY + 1))
    assert_equal 0, @project.knowledge_facts.count
  end

  test "prune caps facts at MAX_FACTS keeping the most recently seen" do
    base = Time.current
    total = KnowledgeFact::MAX_FACTS + 5
    # Build rows directly with spaced last_seen_at so ordering is unambiguous
    # (higher i = more recent), then prune in one pass.
    total.times do |i|
      @project.knowledge_facts.create!(body: "fact number #{i}",
                                       fingerprint: KnowledgeFact.fingerprint("fact number #{i}"),
                                       times_seen: 1, last_seen_at: base + i.seconds)
    end
    KnowledgeFact.prune!(@project)

    assert_equal KnowledgeFact::MAX_FACTS, @project.knowledge_facts.count
    # The 5 oldest (0..4) should be pruned; the newest survives.
    refute @project.knowledge_facts.exists?(fingerprint: KnowledgeFact.fingerprint("fact number 0"))
    assert @project.knowledge_facts.exists?(fingerprint: KnowledgeFact.fingerprint("fact number #{total - 1}"))
  end
end
