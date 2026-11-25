module WorkQueue
  # What myjira reads from homey (~/platform/skchakri/homey), whose release train
  # (homey's ReleaseTrain) tests and merges the PRs of the repos it batches:
  #
  #   * batched?  config/projects.yml lists the repo with `batch: true`. Those repos have no
  #               CI per PR: homey merges ready PRs onto batch/<time>, CI runs once there, and
  #               main moves forward when it is green. So the Bundler skips its local suite
  #               for them, and the queue says "Testing on homey" rather than "Ready to merge".
  #   * failure   homey's Redis says a PR failed a batch on its own at its current commit
  #               (homey:train:failed:<repo>, the culprit after a bisect), with the batch's
  #               note from homey:train:history:<repo>.
  #
  # Both are local reads (a file and Redis): nothing here calls GitHub. The file path and
  # homey's Redis are configurable (HOMEY_PROJECTS_FILE, HOMEY_REDIS_URL); either one missing
  # just means "not batched" / "nothing known".
  module HomeyTrain
    DEFAULT_FILE = "/home/kalyan/platform/skchakri/homey/config/projects.yml".freeze
    DEFAULT_REDIS = "redis://127.0.0.1:6379/5".freeze # homey's own default (Homey.redis)
    HISTORY_READ = 20

    Failure = Struct.new(:number, :checks, :note, :url, keyword_init: true)

    module_function

    def file = ENV.fetch("HOMEY_PROJECTS_FILE", DEFAULT_FILE)

    # "owner/name" of every repo homey batches. Re-read only when the file changes.
    def batched_repos
      stamp = File.mtime(file)
      return @batched[1] if @batched && @batched[0] == [file, stamp]

      @batched = [[file, stamp], parse(File.read(file))]
      @batched[1]
    rescue SystemCallError, Psych::Exception
      Set.new
    end

    def batched?(repo) = repo.present? && batched_repos.include?(repo.to_s.downcase)

    def parse(text)
      shared = YAML.safe_load(text, aliases: true).to_h.fetch("shared", {}).to_h
      owner = shared["owner"].to_s
      Array(shared["projects"]).select { |p| p.is_a?(Hash) && p["batch"] }.to_set { |p| "#{owner}/#{p['repo']}".downcase }
    end

    def reset! = @batched = nil

    def redis = @redis ||= Redis.new(url: ENV.fetch("HOMEY_REDIS_URL", DEFAULT_REDIS), connect_timeout: 0.5, read_timeout: 1)

    # The culprit record for PR `number` at `head_sha`, or nil (not a culprit, a newer
    # commit since, or homey's Redis cannot be reached).
    def failure(repo, number, head_sha)
      return if repo.blank? || number.blank? || head_sha.blank?
      return unless redis.hget("homey:train:failed:#{repo}", number.to_s) == head_sha

      batch = redis.lrange("homey:train:history:#{repo}", 0, HISTORY_READ - 1).lazy.map { |j| JSON.parse(j) }.find do |b|
        b["status"] == "failed" && Array(b["prs"]).any? { |p| p["number"].to_s == number.to_s }
      end
      note = batch&.dig("note").presence || "##{number} broke a release-train batch on its own"
      Failure.new(number: number.to_i, note: note, checks: checks_from(note), url: "https://github.com/#{repo}/pull/#{number}")
    rescue Redis::BaseError, JSON::ParserError
      nil
    end

    # homey writes "#12 failed test and lint"; the check names are what follows "failed".
    def checks_from(note) = note.to_s[/ failed (.+)\z/, 1].to_s.split(/,? and |, /).compact_blank
  end
end
