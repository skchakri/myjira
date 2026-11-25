require "test_helper"

# A phase whose Claude process ends without a result event (its output was cut
# off) used to raise NoMethodError on nil in after_phase and leave the item
# "running" with no process behind it.
class WorkQueueSupervisorMissingResultTest < ActiveSupport::TestCase
  SLUG = "home-me-x".freeze
  KEY = "#{SLUG}:1".freeze

  setup do
    @dir = Dir.mktmpdir("wq")
    @writer = WorkQueue::QueueWriter.new(dir: @dir)
    @store = WorkQueue::Store.new(dir: @dir)
    redis = WorkQueue::RunState.redis
    redis.scan_each(match: "#{WorkQueue::RunState::PREFIX}:*") { |k| redis.del(k) }
    @writer.add(SLUG, title: "T")
    @writer.set_status(SLUG, 1, "running")
    @log = StringIO.new
    @sup = WorkQueue::Supervisor.new(store: @store, writer: @writer, logger: ActiveSupport::Logger.new(@log))
  end

  teardown { FileUtils.rm_rf(@dir) }

  test "a process that exits cleanly without a result event is a failed phase" do
    choice = WorkQueue::Router::Choice.new(model: "claude-sonnet-5-5", effort: "medium", reason: "r")
    runner = WorkQueue::SessionRunner.new(@store.find(KEY), key: KEY, phase: "plan", choice: choice, cwd: @dir)
    silent = ["sh", "-c", %(cat >/dev/null; echo '{"type":"system","session_id":"S"}')]

    result = runner.stub(:command, silent) { runner.run }

    assert result.exit_ok, "the process itself exited 0"
    assert_nil result.text
    assert_equal "S", result.session_id
    assert result.error, "no result event means the phase did not finish"
    assert(WorkQueue::RunState.stream(KEY).any? { |e| e["kind"] == "error" && e["note"].include?("without a final result") })
  end

  test "a result with no text retries the phase instead of raising" do
    result = WorkQueue::SessionRunner::Result.new(denials: [], exit_ok: true, session_id: "S")
    prompts = []

    @sup.stub(:run_phase, ->(_key, prompt) { prompts << prompt }) do
      @sup.send(:after_phase, @store.find(KEY), KEY, "plan", result)
    end

    assert_equal 1, prompts.size
    assert_includes prompts.first, WorkQueue::Supervisor::NO_RESULT
    assert_equal "1", WorkQueue::RunState.get(KEY)["attempts"]
  end

  test "a result with no text blocks the item once retries are used up" do
    WorkQueue::RunState.set(KEY, { "attempts" => WorkQueue::Supervisor::MAX_ATTEMPTS })
    result = WorkQueue::SessionRunner::Result.new(denials: [], exit_ok: true, error: true)

    @sup.send(:after_phase, @store.find(KEY), KEY, "plan", result)

    item = @store.find(KEY)
    assert_equal "blocked", item.status
    assert(item.log.any? { |l| l["text"].include?(WorkQueue::Supervisor::NO_RESULT) })
  end

  test "an error in an item's thread is logged with the first backtrace lines" do
    @sup.stub(:run_phase, ->(*) { nil.include?("x") }) do
      @sup.send(:launch, KEY)
      @sup.instance_variable_get(:@threads)[KEY].join
    end

    lines = @log.string.lines
    assert_includes lines.first, "[work-queue-runner] #{KEY}: NoMethodError: undefined method"
    assert_equal WorkQueue::Supervisor::BACKTRACE_LINES, lines.size - 1
    assert_includes lines[1], "#{File.basename(__FILE__)}:"
  end

  test "the blocking job pop does not use the connection the item threads write on" do
    assert_not_same WorkQueue::RunState.redis, @sup.jobs_redis
    assert_equal WorkQueue::RunState.redis.connection[:db], @sup.jobs_redis.connection[:db]
  end
end
