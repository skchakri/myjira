require "test_helper"
require "turbo/broadcastable/test_helper"

class TaskTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  setup do
    @project = Project.create!(name: "T", slug: "t-#{SecureRandom.hex(3)}", repo_path: "/tmp/t")
  end

  def in_review_item(**attrs)
    @project.tasks.create!({ title: "Item", item_type: "task", board_state: "in_review",
                             pr_url: "https://github.com/x/y/pull/3", pr_number: 3, pr_state: "open" }.merge(attrs))
  end

  test "dedup_fingerprint normalises case, punctuation and whitespace" do
    assert_equal "fix pendingmigrationerror for worklog events",
                 Task.dedup_fingerprint("Fix  PendingMigrationError for worklog_events!")
    assert_equal Task.dedup_fingerprint("Investigate autopilot running three board items at once"),
                 Task.dedup_fingerprint("  investigate AUTOPILOT running three board-items at once  ")
    assert_equal "", Task.dedup_fingerprint("   ")
    assert_equal "", Task.dedup_fingerprint(nil)
  end

  test "reject_pr! moves an in_review item to failed, clears the merge flag, leaves the PR untouched" do
    item = in_review_item(merge_requested_at: Time.current)
    assert item.reject_pr!
    item.reload
    assert_equal "failed", item.board_state
    assert_nil item.merge_requested_at, "the merge request flag is cleared"
    assert_equal "https://github.com/x/y/pull/3", item.pr_url, "PR is left open on GitHub"
    assert_equal "open", item.pr_state
  end

  test "reject_pr! does not increment autopilot_attempts" do
    item = in_review_item(autopilot_attempts: 0)
    item.reject_pr!
    assert_equal 0, item.reload.autopilot_attempts
  end

  test "a rejected item drops out of the daemon merge and poll scopes" do
    item = in_review_item(merge_requested_at: Time.current)
    item.reject_pr!
    assert_not_includes Task.awaiting_merge, item, "no longer queued for gh pr merge"
    assert_not_includes Task.pr_pollable(Time.current), item, "no longer polled for an external merge/close"
  end

  test "reject_pr! with a reason logs a comment and stamps agent_notes" do
    item = in_review_item
    assert_difference -> { item.comments.count }, 1 do
      item.reject_pr!(note: "needs design review")
    end
    assert_equal "Rejected: needs design review", item.comments.last.body
    assert_equal "Rejected: needs design review", item.reload.agent_notes
  end

  test "reject_pr! is a no-op unless in_review with a PR" do
    planned = @project.tasks.create!(title: "P", item_type: "task", board_state: "planned")
    refute planned.reject_pr!
    assert_equal "planned", planned.reload.board_state

    no_pr = @project.tasks.create!(title: "N", item_type: "task", board_state: "in_review")
    refute no_pr.reject_pr!
    assert_equal "in_review", no_pr.reload.board_state
  end

  test "updating plan, agent_notes or board_state broadcasts a live activity refresh" do
    item = @project.tasks.create!(title: "Live", item_type: "feature")
    assert_turbo_stream_broadcasts [item, :activity], count: 1 do
      item.update!(plan: "## Goal\nDo the thing")
    end
    assert_turbo_stream_broadcasts [item, :activity], count: 1 do
      item.update!(agent_notes: "Branching off main; assuming X.")
    end
    assert_turbo_stream_broadcasts [item, :activity], count: 1 do
      item.update!(board_state: "in_progress")
    end
  end

  test "an unrelated save does not broadcast an activity refresh" do
    item = @project.tasks.create!(title: "Quiet", item_type: "feature")
    assert_no_turbo_stream_broadcasts [item, :activity] do
      item.update!(position: 42)
    end
  end

  # --- Conflict resolution ---------------------------------------------------
  test "conflicting? is true only for a reviewable item gh flags CONFLICTING with no resolution in flight" do
    assert in_review_item(pr_mergeable: "CONFLICTING").conflicting?
    assert_not in_review_item(pr_mergeable: "MERGEABLE").conflicting?, "a clean PR is not conflicting"
    assert_not in_review_item(pr_mergeable: "UNKNOWN").conflicting?, "UNKNOWN (still recomputing) is not actionable"
    assert_not in_review_item(pr_mergeable: nil).conflicting?, "unpolled PRs are not conflicting"
    assert_not in_review_item(pr_mergeable: "CONFLICTING", conflict_resolution_at: Time.current).conflicting?,
               "an item already being resolved is not offered again"
  end

  test "conflicting? is false off the in_review/PR path" do
    planned = @project.tasks.create!(title: "P", item_type: "task", board_state: "planned", pr_mergeable: "CONFLICTING")
    assert_not planned.conflicting?
    no_pr = @project.tasks.create!(title: "N", item_type: "task", board_state: "in_review", pr_mergeable: "CONFLICTING")
    assert_not no_pr.conflicting?, "no PR → not reviewable → not conflicting"
  end

  test "request_conflict_resolution! stamps the in-flight guard for a conflicting item" do
    item = in_review_item(pr_mergeable: "CONFLICTING")
    assert item.request_conflict_resolution!
    assert item.reload.resolving_conflicts?, "conflict_resolution_at is stamped"
    assert_not item.conflicting?, "the button no longer shows while resolution is in flight"
  end

  test "request_conflict_resolution! is a no-op unless the item is conflicting" do
    clean = in_review_item(pr_mergeable: "MERGEABLE")
    refute clean.request_conflict_resolution!
    assert_nil clean.reload.conflict_resolution_at

    twice = in_review_item(pr_mergeable: "CONFLICTING", conflict_resolution_at: 1.minute.ago)
    refute twice.request_conflict_resolution!, "a second call can't queue a second agent"
  end

  # board_ordered: default sort is newest-created first; manual position wins
  test "board_ordered returns newest-created items first when no positions are set" do
    # Create items with explicit created_at to avoid sub-second flakiness
    older = @project.tasks.create!(title: "Older", item_type: "task", board_state: "pending",
                                   created_at: 2.hours.ago)
    newer = @project.tasks.create!(title: "Newer", item_type: "task", board_state: "pending",
                                   created_at: 1.hour.ago)
    newest = @project.tasks.create!(title: "Newest", item_type: "task", board_state: "pending",
                                    created_at: 1.minute.ago)

    # All three have no position (NULL) — newest should come first
    ids = @project.tasks.board_ordered.map(&:id)
    assert_equal [newest.id, newer.id, older.id], ids,
                 "unpositioned items must sort newest-first (created_at DESC)"
  end

  test "board_ordered: a manually set position sorts ahead of unpositioned items" do
    # item with position=1 must come before items with NULL position regardless of created_at
    unpositioned_new = @project.tasks.create!(title: "Unpositioned New", item_type: "task",
                                              board_state: "pending", created_at: 1.minute.ago)
    pinned = @project.tasks.create!(title: "Pinned", item_type: "task",
                                    board_state: "pending", created_at: 1.hour.ago)
    pinned.update_column(:position, 1)

    ids = @project.tasks.board_ordered.map(&:id)
    assert_equal pinned.id, ids.first, "positioned item (position=1) must be first"
    assert_equal unpositioned_new.id, ids.last, "unpositioned new item comes after positioned ones"
  end

  test "board_ordered: two positioned items respect their numeric position order" do
    first_pos = @project.tasks.create!(title: "First", item_type: "task", board_state: "pending")
    second_pos = @project.tasks.create!(title: "Second", item_type: "task", board_state: "pending")
    first_pos.update_column(:position, 1)
    second_pos.update_column(:position, 2)

    ids = @project.tasks.board_ordered.map(&:id)
    assert_equal first_pos.id, ids.first
    assert_equal second_pos.id, ids.second
  end

  # --- Worklog timeline ------------------------------------------------------
  test "a board_state change writes one board.* worklog node, terminal states map to done/failed" do
    item = @project.tasks.create!(title: "x", item_type: "task", board_state: "pending")
    assert_difference -> { item.worklog_events.count }, 1 do
      item.update!(board_state: "in_progress")
    end
    running = item.worklog_events.chronological.last
    assert_equal "board.in_progress", running.name
    assert_equal "running", running.status

    item.update!(board_state: "done")
    assert_equal "done", item.worklog_events.chronological.last.status
  end

  test "touching a non-board_state attribute writes no worklog node" do
    item = @project.tasks.create!(title: "x", item_type: "task", board_state: "pending")
    item.worklog_events.delete_all
    assert_no_difference -> { item.worklog_events.count } do
      item.update!(priority: "high")
    end
  end

  # board_queue_ordered: the autopilot work queue — severity then FIFO, and it must
  # ignore the display `position` entirely so a human's drag never reshuffles work.
  test "board_queue_ordered sorts urgent before normal, then oldest-first within a severity" do
    normal_old = @project.tasks.create!(title: "Normal old", item_type: "task", board_state: "pending",
                                        priority: "normal", created_at: 3.hours.ago)
    urgent_new = @project.tasks.create!(title: "Urgent new", item_type: "task", board_state: "pending",
                                        priority: "urgent", created_at: 1.minute.ago)
    normal_new = @project.tasks.create!(title: "Normal new", item_type: "task", board_state: "pending",
                                        priority: "normal", created_at: 1.hour.ago)

    ids = @project.tasks.board_queue_ordered.map(&:id)
    assert_equal [urgent_new.id, normal_old.id, normal_new.id], ids,
                 "urgent first, then oldest-created normal before newer normal"
  end

  test "board_queue_ordered ignores position so display pins don't reorder the work queue" do
    first_created = @project.tasks.create!(title: "First created", item_type: "task", board_state: "pending",
                                           priority: "normal", created_at: 2.hours.ago)
    second_created = @project.tasks.create!(title: "Second created", item_type: "task", board_state: "pending",
                                            priority: "normal", created_at: 1.hour.ago)
    # A human pins the newer item to the top of the *display* — must not change queue order.
    second_created.update_column(:position, 1)
    first_created.update_column(:position, 99)

    ids = @project.tasks.board_queue_ordered.map(&:id)
    assert_equal [first_created.id, second_created.id], ids,
                 "queue order is FIFO regardless of display position"
  end

  # --- Labels (Labelable concern) -------------------------------------------
  test "labels normalize: strip, downcase, squish, drop blanks, dedupe, order preserved" do
    t = @project.tasks.create!(title: "L", item_type: "task",
                               labels: ["Needs-Human", "  flaky ", "FLAKY", "", "agent  authored"])
    assert_equal ["needs-human", "flaky", "agent authored"], t.reload.labels
  end

  test "labels default to an empty array, never nil" do
    t = @project.tasks.create!(title: "L", item_type: "task")
    assert_equal [], t.reload.labels
  end

  test "labels_text round-trips through the comma-separated form field" do
    t = @project.tasks.new(title: "L", item_type: "task")
    t.labels_text = "Flaky, needs-human ,, flaky"
    t.save!
    assert_equal ["flaky", "needs-human"], t.reload.labels
    assert_equal "flaky, needs-human", t.labels_text
  end

  test "labels accept a bare comma string (defensive for API callers)" do
    t = @project.tasks.create!(title: "L", item_type: "task", labels: "a, b, a")
    assert_equal ["a", "b"], t.reload.labels
  end

  test "with_label returns only rows carrying the label, case-insensitively" do
    flaky = @project.tasks.create!(title: "F", item_type: "task", labels: ["flaky", "needs-human"])
    other = @project.tasks.create!(title: "O", item_type: "task", labels: ["agent-authored"])
    result = @project.tasks.with_label("Flaky")
    assert_includes result, flaky
    assert_not_includes result, other
  end

  test "all_labels returns the distinct sorted set across the relation" do
    @project.tasks.create!(title: "A", item_type: "task", labels: ["flaky", "needs-human"])
    @project.tasks.create!(title: "B", item_type: "task", labels: ["flaky", "agent-authored"])
    assert_equal ["agent-authored", "flaky", "needs-human"], @project.tasks.all_labels
  end

  # --- "What's New" changelog ------------------------------------------------
  test "changelog scope returns only done items that carry a blurb" do
    shipped = @project.tasks.create!(title: "Shipped", item_type: "feature", board_state: "done",
                                     changelog_summary: "You can now do X.", finished_at: 1.hour.ago)
    @project.tasks.create!(title: "Done, no blurb", item_type: "feature", board_state: "done")
    @project.tasks.create!(title: "Blank blurb", item_type: "feature", board_state: "done", changelog_summary: "")
    @project.tasks.create!(title: "Not done", item_type: "feature", board_state: "in_review",
                           changelog_summary: "Has a blurb but not shipped.")

    ids = @project.tasks.changelog.map(&:id)
    assert_equal [shipped.id], ids
  end

  test "changelog scope orders by finished_at desc with NULLS last" do
    older   = @project.tasks.create!(title: "Older",  item_type: "feature", board_state: "done",
                                     changelog_summary: "a", finished_at: 2.days.ago)
    newer   = @project.tasks.create!(title: "Newer",  item_type: "feature", board_state: "done",
                                     changelog_summary: "b", finished_at: 1.hour.ago)
    legacy  = @project.tasks.create!(title: "Legacy", item_type: "feature", board_state: "done",
                                     changelog_summary: "c", finished_at: nil)

    assert_equal [newer.id, older.id, legacy.id], @project.tasks.changelog.map(&:id)
  end

  test "humanized_title strips a leading [tag] prefix" do
    t = @project.tasks.new(title: "[user-req] Per-project What's New")
    assert_equal "Per-project What's New", t.humanized_title
  end

  test "humanized_title falls back to the raw title when stripping leaves nothing" do
    t = @project.tasks.new(title: "[only-a-tag]")
    assert_equal "[only-a-tag]", t.humanized_title
  end

  test "changelog_entry? is true only for a shipped item with a blurb" do
    assert @project.tasks.new(board_state: "done", changelog_summary: "x").changelog_entry?
    assert_not @project.tasks.new(board_state: "done", changelog_summary: "").changelog_entry?
    assert_not @project.tasks.new(board_state: "in_review", changelog_summary: "x").changelog_entry?
  end

  test "changelog_media keeps only image/video attachments" do
    t = @project.tasks.create!(title: "With media", item_type: "feature", board_state: "done",
                               changelog_summary: "shipped")
    t.attachments.attach(io: StringIO.new("png"), filename: "shot.png", content_type: "image/png")
    t.attachments.attach(io: StringIO.new("mp4"), filename: "clip.mp4", content_type: "video/mp4")
    t.attachments.attach(io: StringIO.new("log"), filename: "run.log", content_type: "text/plain")

    names = t.changelog_media.map { |a| a.filename.to_s }.sort
    assert_equal ["clip.mp4", "shot.png"], names
  end

  test "changelog_media is empty when nothing is attached" do
    t = @project.tasks.new(title: "No media", board_state: "done", changelog_summary: "x")
    assert_equal [], t.changelog_media
  end

  test "in_progress scope returns only in_progress items" do
    wip  = @project.tasks.create!(title: "WIP",  item_type: "task", board_state: "in_progress")
    @project.tasks.create!(title: "Pend", item_type: "task", board_state: "pending")
    @project.tasks.create!(title: "Wait", item_type: "task", board_state: "waiting")
    assert_equal [wip.id], @project.tasks.in_progress.pluck(:id)
  end

  # --- Board watch / resume helpers ------------------------------------------

  test "latest_board_launch returns the most recent pipeline launch" do
    task = @project.tasks.create!(title: "Watch me", item_type: "task")
    sl1 = @project.session_launches.create!(prompt: "plan", pipeline_step: "planning", task: task,
                                            created_at: 2.minutes.ago)
    sl2 = @project.session_launches.create!(prompt: "eng",  pipeline_step: "engineering", task: task)
    assert_equal sl2.id, task.latest_board_launch.id
    assert_not_equal sl1.id, task.latest_board_launch.id
  end

  test "latest_board_launch returns nil when there are no pipeline launches" do
    task = @project.tasks.create!(title: "No pipeline", item_type: "task")
    @project.session_launches.create!(prompt: "ad-hoc", task: task) # no pipeline_step
    assert_nil task.latest_board_launch
  end

  test "live_terminal_url returns URL when task is in_progress and latest launch has tmux_target" do
    task = @project.tasks.create!(title: "WIP", item_type: "task", board_state: "in_progress")
    @project.session_launches.create!(
      prompt: "eng", pipeline_step: "engineering", task: task,
      status: "launched", tmux_target: "myjira:ss-abc"
    )
    assert_equal "http://localhost:7681/?arg=attach&arg=-t&arg=myjira%3Ass-abc",
                 task.live_terminal_url
  end

  test "live_terminal_url returns nil when task is not in_progress" do
    task = @project.tasks.create!(title: "Planned", item_type: "task", board_state: "planned")
    @project.session_launches.create!(
      prompt: "eng", pipeline_step: "engineering", task: task,
      status: "launched", tmux_target: "myjira:ss-abc"
    )
    assert_nil task.live_terminal_url
  end

  test "live_terminal_url returns nil when latest launch has no tmux_target" do
    task = @project.tasks.create!(title: "WIP no tmux", item_type: "task", board_state: "in_progress")
    @project.session_launches.create!(prompt: "eng", pipeline_step: "engineering", task: task)
    assert_nil task.live_terminal_url
  end

  test "resumable_session_id returns the latest board launch session_id" do
    task = @project.tasks.create!(title: "Resume me", item_type: "task")
    sl = @project.session_launches.create!(prompt: "eng", pipeline_step: "engineering", task: task)
    assert_equal sl.session_id, task.resumable_session_id
  end

  test "resumable_session_id returns nil when no pipeline launches" do
    task = @project.tasks.create!(title: "No resume", item_type: "task")
    assert_nil task.resumable_session_id
  end

  # --- Per-session cost -------------------------------------------------------

  test "session_cost_usd sums cost_usd across board pipeline conversations" do
    task = @project.tasks.create!(title: "Cost task", item_type: "task")
    c1 = @project.conversations.create!(session_id: SecureRandom.uuid, cost_usd: 0.0012)
    c2 = @project.conversations.create!(session_id: SecureRandom.uuid, cost_usd: 0.0025)
    @project.session_launches.create!(prompt: "plan", pipeline_step: "planning", task: task,
                                      conversation: c1)
    @project.session_launches.create!(prompt: "eng",  pipeline_step: "engineering", task: task,
                                      conversation: c2)
    assert_in_delta 0.0037, task.session_cost_usd.to_f, 0.0001
  end

  test "session_cost_usd excludes ad-hoc (non-pipeline) launches" do
    task = @project.tasks.create!(title: "Ad-hoc", item_type: "task")
    c = @project.conversations.create!(session_id: SecureRandom.uuid, cost_usd: 0.0050)
    # Ad-hoc: no pipeline_step
    @project.session_launches.create!(prompt: "manual", task: task, conversation: c)
    assert_equal 0, task.session_cost_usd.to_f
  end

  test "session_cost_usd returns zero when no pipeline launches" do
    task = @project.tasks.create!(title: "Empty cost", item_type: "task")
    assert_equal 0, task.session_cost_usd.to_f
  end

  # --- Approval gate ---------------------------------------------------------

  test "wait_reason must be a known value or blank" do
    item = @project.tasks.create!(title: "X", item_type: "task", board_state: "pending")
    item.update!(board_state: "waiting", wait_reason: "needs_input")
    assert item.needs_input?
    item.update!(wait_reason: "awaiting_approval")
    assert item.awaiting_approval?
    item.wait_reason = "bogus"
    assert_not item.valid?
  end

  test "leaving the waiting state clears wait_reason" do
    item = @project.tasks.create!(title: "X", item_type: "task",
                                  board_state: "waiting", wait_reason: "awaiting_approval")
    item.update!(board_state: "planned")
    assert_nil item.reload.wait_reason
  end

  test "submit_plan! parks the item awaiting approval with the plan and role" do
    item = @project.tasks.create!(title: "X", item_type: "feature", board_state: "in_progress")
    item.submit_plan!(role: "engineering", plan: "## Plan\nDo the thing")
    item.reload
    assert_equal "waiting", item.board_state
    assert_equal "awaiting_approval", item.wait_reason
    assert_equal "engineering", item.agent_role
    assert_equal "## Plan\nDo the thing", item.plan
    assert item.awaiting_approval?
  end

  test "ask_questions! parks the item needing input with structured questions" do
    item = @project.tasks.create!(title: "X", item_type: "feature", board_state: "in_progress")
    item.ask_questions!(questions: ["Which API key?", "Vertical or horizontal?"])
    item.reload
    assert_equal "waiting", item.board_state
    assert_equal "needs_input", item.wait_reason
    assert_equal 2, item.pending_questions.size
    assert_equal "Which API key?", item.pending_questions.first["q"]
    assert_nil item.pending_questions.first["a"]
    assert item.pending_questions.first["id"].present?
  end

  test "approve_plan! moves an awaiting-approval item to planned and clears wait_reason" do
    item = @project.tasks.create!(title: "X", item_type: "feature", board_state: "waiting",
                                  wait_reason: "awaiting_approval", agent_role: "engineering",
                                  plan: "do it")
    assert item.approve_plan!
    item.reload
    assert_equal "planned", item.board_state
    assert_nil item.wait_reason
  end

  test "approve_plan! refuses an item that is not awaiting approval" do
    item = @project.tasks.create!(title: "X", item_type: "feature", board_state: "waiting",
                                  wait_reason: "needs_input")
    assert_not item.approve_plan!
    assert_equal "waiting", item.reload.board_state
  end

  test "record_answers! fills answers by question id" do
    item = @project.tasks.create!(title: "X", item_type: "feature", board_state: "waiting",
                                  wait_reason: "needs_input",
                                  pending_questions: [{ "id" => "q1", "q" => "Key?", "a" => nil }])
    item.record_answers!("q1" => "Use Pexels")
    assert_equal "Use Pexels", item.reload.pending_questions.first["a"]
  end

  test "request_changes! bumps plan_version and logs the note" do
    item = @project.tasks.create!(title: "X", item_type: "feature", board_state: "waiting",
                                  wait_reason: "awaiting_approval", agent_role: "engineering", plan: "v1")
    assert_equal 1, item.plan_version
    item.request_changes!(note: "Use a different template")
    item.reload
    assert_equal 2, item.plan_version
    assert_equal 1, item.comments.where(author: "you").count
    assert item.awaiting_approval?, "stays awaiting approval until the planner re-parks it"
  end
end
