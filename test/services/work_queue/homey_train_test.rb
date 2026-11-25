require "test_helper"

class WorkQueueHomeyTrainTest < ActiveSupport::TestCase
  REPO = "skchakri/ownsites".freeze
  YAML_TEXT = <<~YAML.freeze
    shared:
      owner: skchakri
      projects:
        - { repo: ownsites, name: OwnSites, batch: true }
        - { repo: Homey, name: Homey, batch: true, auto_deploy: true }
        - { repo: ai_service, name: AI Service }
  YAML

  setup do
    @redis = WorkQueue::RunState.redis
    @keys = ["homey:train:failed:#{REPO}", "homey:train:history:#{REPO}"]
    @redis.del(*@keys)
    WorkQueue::HomeyTrain.reset!
  end

  teardown do
    @redis.del(*@keys)
    WorkQueue::HomeyTrain.reset!
  end

  test "batched repos come from homey's projects.yml, re-read when the file changes" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "projects.yml")
      File.write(path, YAML_TEXT)
      with_env("HOMEY_PROJECTS_FILE" => path) do
        assert WorkQueue::HomeyTrain.batched?(REPO)
        assert WorkQueue::HomeyTrain.batched?("skchakri/homey")
        assert_not WorkQueue::HomeyTrain.batched?("skchakri/ai_service")
        assert_not WorkQueue::HomeyTrain.batched?(nil)

        File.write(path, YAML_TEXT.sub("ownsites, name: OwnSites, batch: true", "ownsites, name: OwnSites"))
        File.utime(1.minute.from_now.to_time, 1.minute.from_now.to_time, path)
        assert_not WorkQueue::HomeyTrain.batched?(REPO)
      end
    end
  end

  test "a missing projects file means nothing is batched" do
    with_env("HOMEY_PROJECTS_FILE" => "/nonexistent/projects.yml") { assert_not WorkQueue::HomeyTrain.batched?(REPO) }
  end

  test "failure reads homey's culprit record at the PR's current commit, with the batch note" do
    @redis.hset("homey:train:failed:#{REPO}", "12", "abc")
    @redis.lpush("homey:train:history:#{REPO}", { status: "failed", prs: [{ number: 12 }], note: "#12 failed test, lint and e2e" }.to_json)
    WorkQueue::HomeyTrain.stub(:redis, -> { @redis }) do
      f = WorkQueue::HomeyTrain.failure(REPO, 12, "abc")
      assert_equal %w[test lint e2e], f.checks
      assert_equal "https://github.com/#{REPO}/pull/12", f.url
      assert_nil WorkQueue::HomeyTrain.failure(REPO, 12, "newer"), "a new commit is not the culprit any more"
      assert_nil WorkQueue::HomeyTrain.failure(REPO, 13, "abc")
    end
  end

  test "homey's Redis being unreachable reads as nothing known" do
    down = Object.new
    def down.hget(*) = raise(Redis::CannotConnectError, "down")
    WorkQueue::HomeyTrain.stub(:redis, -> { down }) { assert_nil WorkQueue::HomeyTrain.failure(REPO, 12, "abc") }
  end

  private

  def with_env(vars)
    old = vars.keys.index_with { |k| ENV[k] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end
end
