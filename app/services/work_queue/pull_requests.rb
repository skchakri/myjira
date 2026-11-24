require "open3"

module WorkQueue
  # PR status + merges via the gh CLI (squash). Merging is the one action the
  # web view performs itself; queue status updates still go through the session.
  class PullRequests
    Status = Struct.new(:url, :number, :state, :base, :head, :mergeable, :merge_state,
                        :head_sha, :merge_sha, :failed_checks, keyword_init: true) do
      def conflicts? = mergeable == "CONFLICTING"
      def merged? = state == "MERGED"
      def failed_checks? = Array(failed_checks).any?
      # "owner/name" from the PR URL.
      def repo = url.to_s[%r{github\.com/([^/]+/[^/]+)/pull/}, 1]
      def behind? = merge_state == "BEHIND"
      def open? = state == "OPEN"
    end
    Result = Struct.new(:ok, :steps, keyword_init: true)

    FIELDS = "number,state,baseRefName,headRefName,mergeable,mergeStateStatus,url,headRefOid,mergeCommit,statusCheckRollup".freeze
    # Check-run conclusions / status-context states that count as red.
    FAILED = %w[FAILURE TIMED_OUT CANCELLED ERROR STARTUP_FAILURE].freeze

    # Asked before every gh call; whether gh is installed does not change while we run.
    def self.gh?
      @gh = system("command -v gh >/dev/null 2>&1") if @gh.nil?
      @gh
    end

    def initialize(runner: method(:gh))
      @runner = runner
    end

    # Warm the cache for many PRs at once (gh is ~0.5-1 s per call).
    def prefetch(prs)
      prs.compact.uniq.map { |pr| Thread.new { Rails.application.executor.wrap { status(pr) } } }.each(&:join)
    end

    def status(pr)
      return if pr.blank?

      Rails.cache.fetch(["wq-pr", pr], expires_in: 30.seconds) { fetch(pr) }
    end

    # Uncached gh call.
    def fetch(pr)
      out, ok = @runner.call("pr", "view", pr.to_s, "--json", FIELDS)
      return unless ok

      j = JSON.parse(out)
      Status.new(url: j["url"], number: j["number"], state: j["state"], base: j["baseRefName"],
                 head: j["headRefName"], mergeable: j["mergeable"], merge_state: j["mergeStateStatus"],
                 head_sha: j["headRefOid"], merge_sha: j.dig("mergeCommit", "oid"), failed_checks: failed_checks(j))
    rescue JSON::ParserError
      nil
    end

    # Names of checks that concluded failure / timed_out / cancelled (latest run per name).
    def self.failed_checks(json)
      Array(json["statusCheckRollup"]).filter_map do |c|
        verdict = (c["conclusion"].presence || c["state"]).to_s.upcase
        (c["name"].presence || c["context"]) if FAILED.include?(verdict)
      end.uniq
    end

    def failed_checks(json) = self.class.failed_checks(json)

    # Merge one PR. target "base" = its own base; "main" = retarget to main first.
    def merge(pr, target: "base", main: "main")
      steps = []
      if target == "main"
        st = status(pr)
        steps << run("pr", "edit", pr, "--base", main) if st && st.base != main
      end
      steps << run("pr", "merge", pr, "--squash") if steps.all? { |s| s[:ok] }
      Rails.cache.delete(["wq-pr", pr])
      Result.new(ok: steps.all? { |s| s[:ok] }, steps: steps)
    end

    # Merge a dependency chain (ordered parent → child).
    #   target "base": collapse the stack — children merge into their parent's
    #                  branch first (deepest first), then the root merges into its base.
    #   target "main": root merges first; each child is retargeted to main, then merged.
    def merge_chain(prs, target: "base", main: "main")
      order = target == "main" ? prs : prs.reverse
      steps = []
      order.each do |pr|
        r = merge(pr, target: target == "main" ? "main" : "base", main: main)
        steps.concat(r.steps)
        break unless r.ok
      end
      Result.new(ok: steps.all? { |s| s[:ok] }, steps: steps)
    end

    private

    def run(*args)
      out, ok = @runner.call(*args)
      { cmd: "gh #{args.join(' ')}", ok: ok, out: out.to_s.strip }
    end

    def gh(*args)
      return ["gh CLI not found on this host (the myjira container needs gh + GH_TOKEN)", false] unless self.class.gh?

      out, status = Open3.capture2e("gh", *args)
      [out, status.success?]
    rescue SystemCallError => e
      [e.message, false]
    end
  end
end
