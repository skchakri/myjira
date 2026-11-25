require "test_helper"

class WorkQueueTrainSyncTest < ActiveSupport::TestCase
  SLUG = "home-me-app".freeze
  PR = "https://github.com/me/app/pull/42".freeze

  setup do
    @dir = Dir.mktmpdir("wq")
    @writer = WorkQueue::QueueWriter.new(dir: @dir)
    @store = WorkQueue::Store.new(dir: @dir)
    @redis = WorkQueue::RunState.redis
    @redis.del(WorkQueue::StatusCache.pr_key(PR))
  end

  teardown do
    FileUtils.rm_rf(@dir)
    @redis.del(WorkQueue::StatusCache.pr_key(PR))
  end

  def add(status: "review", bundle: nil)
    n = @writer.add(SLUG, title: "Thing")["n"]
    @writer.update(SLUG, n) do |i|
      i["status"] = status
      i["pr"] = PR
      i["bundle"] = bundle if bundle
    end
    n
  end

  def pr_is(**attrs)
    st = { url: PR, number: 42, state: "OPEN", head_sha: "h1" }.merge(attrs)
    @redis.set(WorkQueue::StatusCache.pr_key(PR), st.to_json)
  end

  def sync(batched: true, failure: nil)
    WorkQueue::TrainSync.new(writer: @writer, failure: ->(*) { failure }, batched: ->(_) { batched }).call(@store.items_for(SLUG))
  end

  def item(n) = @store.items_for(SLUG).find { |i| i.n == n }

  test "a PR the train merged moves its items to done, ready to deploy" do
    a = add
    b = add(status: "blocked", bundle: { "train" => { "checks" => ["CI"] } })
    pr_is(state: "MERGED")
    assert_equal [a, b], sync.map(&:n)
    [a, b].each { |n| assert_equal "done", item(n).status }
    assert_nil item(b).bundle_info["train"]
    assert_match(/merged by homey's release train; ready to deploy/, item(a).log.map { |l| l["text"] }.join)
    assert_empty sync, "nothing left to move"
  end

  test "a PR merged on GitHub in a repo homey does not batch is done too" do
    a = add
    pr_is(state: "MERGED")
    sync(batched: false)
    assert_equal "done", item(a).status
    assert_match(/merged on GitHub/, item(a).log.last(2).first["text"])
  end

  test "homey's culprit record blocks the items with the failing checks and a link" do
    a = add
    pr_is
    failure = WorkQueue::HomeyTrain::Failure.new(number: 42, checks: %w[test lint], note: "#42 failed test and lint", url: PR)
    sync(failure: failure)
    it = item(a)
    assert_equal "blocked", it.status
    assert_equal({ "checks" => %w[test lint], "url" => PR, "sha" => "h1" }, it.bundle_info["train"])
    assert_includes it.log.map { |l| l["text"] }.join, "Failing: test, lint. #{PR}"
    assert_equal ["bad", "Failed on homey's release train"], WorkQueue::Flow.new(it).then { |f| [f.tone, f.label] }
  end

  test "without homey's Redis a failed check on the PR head blocks it" do
    a = add
    pr_is(failed_checks: ["homey/release-train"])
    sync
    assert_equal "blocked", item(a).status
    assert_equal "#{PR}/checks", item(a).bundle_info.dig("train", "url")
  end

  test "an open PR with nothing failed, or in a repo homey does not batch, is left alone" do
    a = add
    pr_is
    assert_empty sync
    pr_is(failed_checks: ["CI"])
    assert_empty sync(batched: false)
    assert_equal "review", item(a).status
  end
end
