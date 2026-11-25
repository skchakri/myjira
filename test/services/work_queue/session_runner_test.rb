require "test_helper"

class WorkQueueSessionRunnerTest < ActiveSupport::TestCase
  SLUG = "home-me-x".freeze
  KEY = "#{SLUG}:1".freeze

  setup do
    @dir = Dir.mktmpdir("wq")
    WorkQueue::QueueWriter.new(dir: @dir).add(SLUG, title: "T")
    @item = WorkQueue::Store.new(dir: @dir).find(KEY)
    redis = WorkQueue::RunState.redis
    redis.scan_each(match: "#{WorkQueue::RunState::PREFIX}:*") { |k| redis.del(k) }
  end

  teardown { FileUtils.rm_rf(@dir) }

  # `claude -p` waits 3 seconds for stdin, then exits with "Input must be provided…".
  # on_spawn writes the pid to Redis and once stalled behind a blocking pop for longer.
  test "the prompt reaches the process before on_spawn runs, however long that takes" do
    choice = WorkQueue::Router::Choice.new(model: "claude-sonnet-5-5", effort: "medium", reason: "r")
    runner = WorkQueue::SessionRunner.new(@item, key: KEY, phase: "plan", choice: choice, cwd: @dir)
    got = File.join(@dir, "prompt.txt")
    reader = ["sh", "-c", %(cat > "$0.part"; mv "$0.part" "$0"; echo '{"type":"result","result":"ok"}'), got]
    seen = nil
    wait = lambda do |_pid|
      40.times { File.exist?(got) ? break : sleep(0.05) }
      seen = File.exist?(got) && File.read(got)
    end

    result = runner.stub(:command, reader) { runner.run(on_spawn: wait) }

    assert_equal runner.prompt, seen, "stdin was written and closed before on_spawn was called"
    assert_equal "ok", result.text
  end
end
