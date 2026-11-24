require "test_helper"

class WorkQueueInboxTest < ActiveSupport::TestCase
  PERMISSION = %w[Allow\ once Always\ allow\ in\ this\ project Deny].freeze

  setup do
    @dir = Dir.mktmpdir("wq-inbox")
    @old = ENV["WORK_QUEUE_DIR"]
    ENV["WORK_QUEUE_DIR"] = @dir
    redis = WorkQueue::RunState.redis
    redis.scan_each(match: "#{WorkQueue::RunState::PREFIX}:*") { |k| redis.del(k) }
    write("home-me-app", [
      { n: 1, title: "Pick a colour", status: "blocked", updatedAt: ms(4.days.ago),
        questions: [{ q: "Which colour?", at: ms(4.days.ago), options: %w[red blue] }] },
      { n: 2, title: "Run the specs", status: "blocked", updatedAt: ms(2.hours.ago),
        questions: [{ q: "Permission: Bash bundle exec rspec spec/a_spec.rb?", at: ms(2.hours.ago), options: PERMISSION },
                    { q: "Permission: Bash bin/rubocop app?", at: ms(1.hour.ago), options: PERMISSION }] },
      { n: 3, title: "A suggested follow-up", status: "triage", awaitingApproval: true, updatedAt: ms(1.hour.ago) },
      { n: 4, title: "Ready thing", status: "review", pr: "https://github.com/o/r/pull/12", updatedAt: ms(5.minutes.ago),
        log: [{ at: ms(26.hours.ago), text: "→ review" }, { at: ms(5.minutes.ago), text: "PR checked" }] },
      { n: 5, title: "Went quiet", status: "running", updatedAt: ms(2.hours.ago) },
      { n: 6, title: "Stuck", status: "blocked", updatedAt: ms(3.hours.ago), log: [{ at: ms(3.hours.ago), text: "→ blocked" }] },
      { n: 7, title: "Waiting its turn", status: "queued", updatedAt: ms(1.hour.ago) },
      { n: 8, title: "Shipped", status: "done", updatedAt: ms(1.hour.ago) }
    ])
    write("home-me-other", [
      { n: 1, title: "Older decision", status: "blocked", updatedAt: ms(6.days.ago),
        questions: [{ q: "Ship it?", at: ms(6.days.ago), options: %w[yes no] }] }
    ])
  end

  teardown do
    ENV["WORK_QUEUE_DIR"] = @old
    FileUtils.rm_rf(@dir)
  end

  test "sections hold what needs the person, in display order, and leave the rest out" do
    inbox = WorkQueue::Inbox.new
    assert_equal %w[decisions permissions approve review stalled failed], inbox.sections.map(&:first)
    by = inbox.sections.to_h { |key, _, entries| [key, entries.map(&:key)] }
    assert_equal ["home-me-other:1", "home-me-app:1"], by["decisions"], "oldest first, across projects"
    assert_equal ["home-me-app:2"], by["permissions"]
    assert_equal ["home-me-app:3"], by["approve"]
    assert_equal ["home-me-app:4"], by["review"]
    assert_equal ["home-me-app:5"], by["stalled"]
    assert_equal ["home-me-app:6"], by["failed"]
    assert_equal 7, inbox.total
  end

  test "waiting age comes from the question, the status change or the stall" do
    entries = WorkQueue::Inbox.new.entries.index_by(&:key)
    asked = entries["home-me-app:1"].flow
    assert_equal "late", asked.waiting_level
    assert_match(/\A4d \d+h\z/, asked.waiting_words)

    review = entries["home-me-app:4"].flow
    assert_equal "warn", review.waiting_level, "counted from the → review line, not the later log line"
    assert_match(/\A1d 2h\z/, review.waiting_words)

    perms = entries["home-me-app:2"].flow
    assert_nil perms.waiting_level
    assert_match(/\A2h \d+m\z/, perms.waiting_words, "the oldest open question")

    assert_match(/\A2h \d+m\z/, entries["home-me-app:5"].flow.waiting_words)
    assert_nil WorkQueue::Flow.new(WorkQueue::Store.new.find("home-me-app:7")).waiting_since
  end

  test "summary counts prompts, not items, and calls out what is over three days" do
    inbox = WorkQueue::Inbox.new
    assert_equal "2 decisions · 2 permission prompts · 1 to approve · 1 to review · 1 stalled · 1 failed · 2 waiting over 3 days",
                 inbox.summary_line
    assert_equal 2, inbox.overdue
    assert_equal({ "total" => 7, "overdue" => 2 }, WorkQueue::Inbox.counts)
  end

  test "an empty queue reads as nothing needs you" do
    FileUtils.rm_f(Dir.glob(File.join(@dir, "*.json")))
    inbox = WorkQueue::Inbox.new
    assert_predicate inbox, :empty?
    assert_equal "Nothing needs you.", inbox.summary_line
    assert_empty inbox.sections
  end

  private

  def ms(time) = (time.to_f * 1000).to_i

  def write(slug, items)
    rows = items.map { |i| { questions: [], log: [], createdAt: i[:updatedAt] }.merge(i) }
    File.write(File.join(@dir, "#{slug}.json"), { items: rows }.to_json)
  end
end
