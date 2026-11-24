require "test_helper"

# Errands ("kind": "yours"): tasks only the person can do. They read "Yours", sit outside
# the agent pipeline (no stall, no runner start, no follow-up limit), and the inbox lists them.
class WorkQueueErrandsTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  SLUG = "home-me-app".freeze

  setup do
    @dir = Dir.mktmpdir("wq-errands")
    @old = ENV["WORK_QUEUE_DIR"]
    ENV["WORK_QUEUE_DIR"] = @dir
    @writer = WorkQueue::QueueWriter.new(dir: @dir)
    @store = WorkQueue::Store.new(dir: @dir)
    redis = WorkQueue::RunState.redis
    redis.scan_each(match: "#{WorkQueue::RunState::PREFIX}:*") { |k| redis.del(k) }
  end

  teardown do
    ENV["WORK_QUEUE_DIR"] = @old
    FileUtils.rm_rf(@dir)
  end

  def item(**attrs)
    WorkQueue::Store::Item.new(slug: "app", n: 1, title: "T", status: "blocked", questions: [], log: [], kind: "yours", **attrs)
  end

  def flow(item) = WorkQueue::Flow.new(item)
  def ms(time) = (time.to_f * 1000).to_i

  def write(items)
    rows = items.map { |i| { questions: [], log: [], createdAt: i[:updatedAt] || ms(1.hour.ago), updatedAt: ms(1.hour.ago) }.merge(i) }
    File.write(File.join(@dir, "#{SLUG}.json"), { items: rows }.to_json)
  end

  test "an errand reads Yours with its due date, in its own tone, and never needs-you or failed" do
    travel_to Time.zone.local(2026, 11, 24, 10) do
      plain = flow(item)
      assert_equal ["mine", "Yours"], [plain.tone, plain.label]
      assert_equal %w[all open yours], plain.tags
      assert_equal "Do it, then tick it off. No agent will pick this up.", plain.your_part

      assert_equal "Yours · due Nov 28", flow(item(due: Date.new(2026, 11, 28))).label
      today = flow(item(due: Date.new(2026, 11, 24)))
      assert_equal ["Yours · due today", "warn"], [today.label, today.waiting_level]
      assert_includes today.tags, "due"
      late = flow(item(due: Date.new(2026, 11, 22)))
      assert_equal ["Yours · overdue 2d", "late"], [late.label, late.waiting_level]

      snoozed = flow(item(snoozed_until: Time.zone.local(2026, 11, 30, 8), due: Date.new(2026, 11, 22)))
      assert_equal ["wait", "Snoozed until Mon"], [snoozed.tone, snoozed.label]
      assert_equal %w[all open yours snoozed], snoozed.tags
      assert_equal "Yours", flow(item(snoozed_until: Time.zone.local(2026, 11, 23, 8))).label, "a snooze that has ended"
    end
  end

  test "an errand has no agent phases: 0% until done, then 100%, and it never stalls" do
    quiet = flow(item(status: "running", updated_at: 3.days.ago))
    assert_not quiet.stalled?
    assert_equal "Yours", quiet.label
    assert_equal 0, quiet.percent
    assert_nil flow(item(yours_at: 5.days.ago)).waiting_level, "an errand with no due date does not nag by age"
    assert_equal "5d 0h", flow(item(yours_at: 5.days.ago)).waiting_words

    done = flow(item(status: "done"))
    assert_equal ["ok", "Done by you", 100], [done.tone, done.label, done.percent]
    assert done.finished?
  end

  test "an errand child rolls up into its parent's done count and does not block the bundle" do
    parent = WorkQueue::Store::Item.new(slug: "app", n: 1, title: "P", status: "done", questions: [], log: [])
    kids = [item(n: 2, parent: 1, status: "queued"), item(n: 3, parent: 1, status: "done")]
    roll = WorkQueue::Progress.new([parent, *kids]).for(parent)
    assert_equal [2, 1, 67], [roll.total, roll.done, roll.percent]
    assert_empty roll.need_you
    assert_not WorkQueue::Bundler.new.send(:member?, kids.first)
  end

  test "the queue file carries kind, due, snoozedUntil and yoursAt, and unmarking removes them" do
    @writer.add(SLUG, title: "Call the practice")
    till = Time.zone.local(2026, 12, 1, 8)
    @writer.errand(SLUG, 1, { kind: "yours", due: "2026-11-28", snoozedUntil: ms(till), yoursAt: ms(Time.current) }, log: "Marked")
    found = @store.find("#{SLUG}:1")
    assert found.yours?
    assert_equal "triage", found.status, "marking does not change the status"
    assert_equal [Date.new(2026, 11, 28), till], [found.due, found.snoozed_until]

    @writer.errand(SLUG, 1, { kind: nil, due: nil, snoozedUntil: nil, yoursAt: nil })
    raw = JSON.parse(File.read(File.join(@dir, "#{SLUG}.json")))["items"].first
    assert_empty raw.keys & %w[kind due snoozedUntil yoursAt]
    assert_not @store.find("#{SLUG}:1").yours?
  end

  test "the runner refuses to start an errand and says why on the item" do
    @writer.add(SLUG, title: "Collect receipts")
    @writer.errand(SLUG, 1, { kind: "yours" })
    WorkQueue::Supervisor.new(store: @store, writer: @writer).handle({ "action" => "start", "key" => "#{SLUG}:1", "force" => true })
    assert_empty WorkQueue::RunState.redis.lrange("#{WorkQueue::RunState::PREFIX}:waiting", 0, -1)
    found = @store.find("#{SLUG}:1")
    assert_equal "triage", found.status
    assert_match(/Not started: this is an errand for you/, found.log.last["text"])
  end

  test "errands never count toward the follow-up limit and the child starter leaves them alone" do
    write([
      { n: 1, title: "Parent", status: "review" },
      { n: 2, title: "Confirm with the practice", status: "blocked", kind: "yours" },
      { n: 3, title: "Ask the vendor", status: "review", kind: "yours" },
      { n: 4, title: "Errand follow-up", status: "triage", parent: 1, kind: "yours", createdAt: ms(1.minute.ago) }
    ])
    items = @store.items_for(SLUG)
    assert_equal 1, WorkQueue::Inbox.waiting_count(items, store: @store), "only the parent in review waits on the person"

    jobs = []
    starter = WorkQueue::ChildStarter.new(writer: @writer, enqueue: ->(action, key) { jobs << [action, key] },
                                          limit: ->(_) { }, waiting: ->(_) { 0 }, since: 1.hour.ago)
    assert_empty starter.call(items)
    assert_empty jobs
  end

  test "the inbox lists errands after decisions: overdue and due first, then by age, snoozed folded away" do
    travel_to Time.zone.local(2026, 11, 24, 10) do
      write([
        { n: 1, title: "Pick a colour", status: "blocked", questions: [{ q: "Which?", at: ms(2.hours.ago), options: %w[a b] }] },
        { n: 2, title: "No date, old", status: "blocked", kind: "yours", yoursAt: ms(6.days.ago) },
        { n: 3, title: "No date, new", status: "review", kind: "yours", yoursAt: ms(1.hour.ago) },
        { n: 4, title: "Due later", status: "queued", kind: "yours", due: "2026-11-30", yoursAt: ms(1.hour.ago) },
        { n: 5, title: "Overdue", status: "blocked", kind: "yours", due: "2026-11-21", yoursAt: ms(2.hours.ago) },
        { n: 6, title: "Due today", status: "running", kind: "yours", due: "2026-11-24", yoursAt: ms(3.hours.ago), updatedAt: ms(2.days.ago) },
        { n: 7, title: "Put away", status: "blocked", kind: "yours", snoozedUntil: ms(Time.zone.local(2026, 11, 27, 8)), due: "2026-11-20" },
        { n: 8, title: "Ticked off", status: "done", kind: "yours" },
        { n: 9, title: "Stuck agent work", status: "blocked", log: [{ at: ms(3.hours.ago), text: "→ blocked" }] }
      ])
      inbox = WorkQueue::Inbox.new(store: @store)
      assert_equal %w[decisions yours failed], inbox.sections.map(&:first)
      yours = inbox.sections.to_h { |key, _, entries| [key, entries.map { |e| e.item.n }] }["yours"]
      assert_equal [5, 6, 4, 2, 3], yours
      assert_equal [7], inbox.snoozed.map { |e| e.item.n }
      assert_equal [9], inbox.sections.last.last.map { |e| e.item.n }, "errands leave Failed / Stalled / Review"

      assert_includes inbox.summary.map(&:last), "5 yours (1 overdue)"
      assert_equal 0, inbox.overdue, "\"waiting over 3 days\" is about agent work, not errands"
      assert_equal 4, inbox.total, "sidebar: the decision, the failed task, and only the two errands due or overdue"
      assert_equal [5, 6], inbox.errands_due.map { |e| e.item.n }
    end
  end

  test "the hint fires on person-only wording for blocked or review tasks without a PR, and only there" do
    yes = [
      "A thru Z: confirm with the practice: Google shows 5:30 PM closing for Stone Oak",
      "a-zpeds: ask the practice for provider backgrounds (26 \"write a bio\" gaps)",
      "A thru Z: confirm the 7 remaining found listings (Yelp on Main St)",
      "Collect MashData Q4-2026 receipts + invoices (Oct 1 – Nov 17)",
      "Joy off-site: Google reviews, claim Healthgrades (accepting new patients)",
      "Buy a C2PA-trusted signing cert + wire it into the renderer",
      "Get TikTok video.upload scope approved, set TIKTOK_UPLOAD_SCOPE=1",
      "Optional: record a real 45s demo video for the PH listing"
    ]
    no = [
      "Hide PWP site photos while demonstrator is unsubscribed",
      "AI visibility noun: health sites with a medical schema type but blank industry now read \"business\"",
      "Expire the AI visibility fixes cache on page edit, review sync, and GBP connect",
      "After deploy: confirm hidden photo URLs return 403 on TST/PRD",
      "Landing: confirm or soften \"Managed Google ad campaigns\" copy",
      "OS-306 Paid ads (Google + Meta), managed service first",
      "Sign in page: the API call fails when the payment form is open",
      "Embed C2PA/IPTC AI provenance metadata in rendered MP4"
    ]
    yes.each { |t| assert WorkQueue::Errands.looks_like?(t), t }
    no.each { |t| assert_not WorkQueue::Errands.looks_like?(t), t }

    plain = ->(**attrs) { item(kind: nil, title: yes.first, **attrs) }
    assert WorkQueue::Errands.suggest?(plain.call(status: "blocked"), run: {})
    assert WorkQueue::Errands.suggest?(plain.call(status: "review"), run: {})
    assert_not WorkQueue::Errands.suggest?(plain.call(status: "running"), run: {})
    assert_not WorkQueue::Errands.suggest?(plain.call(status: "review", pr: "https://github.com/o/r/pull/3"), run: {})
    assert_not WorkQueue::Errands.suggest?(plain.call(kind: "yours"), run: {})
    assert_not WorkQueue::Errands.suggest?(plain.call, run: { WorkQueue::Errands::HINT_OFF => "1" }), "waved away before"
  end

  test "a snooze ends at 8 in the morning: a day, three days, next Monday or a picked date" do
    now = Time.zone.local(2026, 11, 24, 15) # a Tuesday
    at = ->(value) { WorkQueue::Errands.snooze_until(value, now: now) }
    assert_equal Time.zone.local(2026, 11, 25, 8), at.call("1d")
    assert_equal Time.zone.local(2026, 11, 27, 8), at.call("3d")
    assert_equal Time.zone.local(2026, 11, 30, 8), at.call("monday")
    assert_equal Time.zone.local(2026, 12, 5, 8), at.call("2026-12-05")
    assert_nil at.call("2026-11-20"), "a day in the past"
    assert_nil at.call("soon")
  end

  test "the list counts errands under their own chip and always draws them" do
    write([
      { n: 1, title: "Agent work", status: "review" },
      { n: 2, title: "Mine", status: "blocked", kind: "yours" },
      { n: 3, title: "Mine too", status: "queued", kind: "yours", snoozedUntil: ms(2.days.from_now) },
      { n: 4, title: "Mine, done", status: "done", kind: "yours" }
    ])
    listing = WorkQueue::Listing.new(SLUG, @store.items_for(SLUG), store: @store)
    assert_equal 2, listing.counts["yours"]
    assert_equal 1, listing.need, "errands are not \"need you\""
    assert_equal 0, listing.failed, "a blocked errand is not failed"
    assert_superset listing.shown, Set[2, 3]
  end

  def assert_superset(set, part) = assert(part.subset?(set), "#{set.inspect} should include #{part.inspect}")
end
