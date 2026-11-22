require "open3"

module WorkQueue
  # PR status + merges via the gh CLI (squash). Merging is the one action the
  # web view performs itself; queue status updates still go through the session.
  class PullRequests
    Status = Struct.new(:url, :number, :state, :base, :head, :mergeable, :merge_state, keyword_init: true) do
      def conflicts? = mergeable == "CONFLICTING"
      def behind? = merge_state == "BEHIND"
      def open? = state == "OPEN"
    end
    Result = Struct.new(:ok, :steps, keyword_init: true)

    FIELDS = "number,state,baseRefName,headRefName,mergeable,mergeStateStatus,url".freeze

    def self.gh? = system("command -v gh >/dev/null 2>&1")

    def initialize(runner: method(:gh))
      @runner = runner
    end

    # Warm the cache for many PRs at once (gh is ~0.5-1 s per call).
    def prefetch(prs)
      prs.compact.uniq.map { |pr| Thread.new { Rails.application.executor.wrap { status(pr) } } }.each(&:join)
    end

    def status(pr)
      return if pr.blank?

      Rails.cache.fetch(["wq-pr", pr], expires_in: 30.seconds) do
        out, ok = @runner.call("pr", "view", pr.to_s, "--json", FIELDS)
        next unless ok

        j = JSON.parse(out)
        Status.new(url: j["url"], number: j["number"], state: j["state"], base: j["baseRefName"],
                   head: j["headRefName"], mergeable: j["mergeable"], merge_state: j["mergeStateStatus"])
      rescue JSON::ParserError
        nil
      end
    end

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
