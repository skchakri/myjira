require "test_helper"

class BoardTicketFromSessionJobTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Enrich", slug: "enrich-#{SecureRandom.hex(3)}",
                               repo_path: "/tmp/enrich-#{SecureRandom.hex(3)}")
    @convo = Conversation.create!(session_id: SecureRandom.uuid, project: @project)
    add_user("Add a dark mode toggle to the navbar")
    add_user("Now fix the failing auth spec")
    Setting.auto_board_tickets = true
  end

  def add_user(body)
    @convo.conversation_messages.create!(
      ext_id: SecureRandom.uuid, role: "user", kind: "message", body: body,
      position: (@convo.conversation_messages.maximum(:position) || -1) + 1,
      occurred_at: Time.current
    )
  end

  def cli_envelope(topics)
    { result: { topics: topics }.to_json, is_error: false }.to_json
  end

  def two_topics
    [
      { topic_key: "dark-mode-toggle", title: "Add dark mode toggle", item_type: "feature",
        asks: ["Add a dark mode toggle to the navbar"], done: "Added the toggle",
        assumptions: "Tailwind tokens exist", test_plan: "Toggle flips theme", pros_cons: "Pro: nice. Con: none" },
      { topic_key: "fix-auth-spec", title: "Fix failing auth spec", item_type: "issue",
        asks: ["Now fix the failing auth spec"], done: "Fixed the spec",
        assumptions: "Spec was flaky", test_plan: "bin/rails test passes", pros_cons: "Pro: green" }
    ]
  end

  def run_with(canned)
    job = BoardTicketFromSessionJob.new
    job.stub(:run_claude, canned) { job.perform(@convo.id) }
  end

  test "creates one ticket per topic with stable external_ref, item_type and title" do
    assert_difference -> { @project.tasks.count }, 2 do
      run_with(cli_envelope(two_topics))
    end

    dark = @project.tasks.find_by(external_ref: "cli:#{@convo.session_id}:dark-mode-toggle")
    auth = @project.tasks.find_by(external_ref: "cli:#{@convo.session_id}:fix-auth-spec")
    assert dark, "dark mode ticket exists"
    assert_equal "feature", dark.item_type
    assert_equal "Add dark mode toggle", dark.title
    assert_equal "pending", dark.board_state
    assert_equal @convo.id, dark.last_conversation_id
    assert_equal "issue", auth.item_type
  end

  test "implementation_notes holds all four enrichment sections" do
    run_with(cli_envelope(two_topics))
    notes = @project.tasks.find_by(external_ref: "cli:#{@convo.session_id}:dark-mode-toggle").implementation_notes
    assert_includes notes, "What Claude did"
    assert_includes notes, "Assumptions"
    assert_includes notes, "Test plan"
    assert_includes notes, "Pros & cons"
    assert_includes notes, "Added the toggle"
  end

  test "asks land in the managed description block" do
    run_with(cli_envelope(two_topics))
    desc = @project.tasks.find_by(external_ref: "cli:#{@convo.session_id}:dark-mode-toggle").description
    assert_includes desc, "<!-- auto:asks -->"
    assert_includes desc, "- Add a dark mode toggle to the navbar"
  end

  test "re-running appends no duplicate tickets and does not duplicate asks" do
    run_with(cli_envelope(two_topics))
    assert_no_difference -> { @project.tasks.count } do
      run_with(cli_envelope(two_topics))
    end
    desc = @project.tasks.find_by(external_ref: "cli:#{@convo.session_id}:dark-mode-toggle").description
    assert_equal 1, desc.scan("- Add a dark mode toggle to the navbar").size
    assert_equal 1, desc.scan("<!-- auto:asks -->").size
  end

  test "preserves human-authored prose above the managed asks block" do
    run_with(cli_envelope(two_topics))
    task = @project.tasks.find_by(external_ref: "cli:#{@convo.session_id}:dark-mode-toggle")
    task.update!(description: "Human note here\n\n#{task.description}")
    run_with(cli_envelope(two_topics))
    assert_includes task.reload.description, "Human note here"
  end

  test "claude failure still records a fallback ticket with no enrichment and does not raise" do
    failing = ->(*) { raise "claude CLI exited 1" }
    job = BoardTicketFromSessionJob.new
    assert_difference -> { @project.tasks.count }, 1 do
      assert_nothing_raised { job.stub(:run_claude, failing) { job.perform(@convo.id) } }
    end
    task = @project.tasks.find_by(external_ref: "cli:#{@convo.session_id}:session")
    assert task, "fallback ticket exists"
    assert_includes task.description, "- Add a dark mode toggle to the navbar"
    # All four enrichment sections present but empty (—), throttle left open for retry.
    assert_equal 4, task.implementation_notes.scan("—").size
    assert_nil @convo.reload.board_enriched_at
  end

  test "successful pass stamps the throttle so it does not re-fire without new asks" do
    run_with(cli_envelope(two_topics))
    @convo.reload
    assert_not_nil @convo.board_enriched_at
    assert_equal 2, @convo.board_enriched_count
    assert_not @convo.board_enrich_due?
  end

  test "respects the global kill switch" do
    Setting.auto_board_tickets = false
    assert_no_difference -> { @project.tasks.count } do
      run_with(cli_envelope(two_topics))
    end
  end
end
