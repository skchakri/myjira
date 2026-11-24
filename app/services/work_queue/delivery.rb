require "open3"

module WorkQueue
  # Where a PR is after review: testing together on a release-train batch,
  # deploying, live, or merged but not live yet. Read straight from GitHub
  # Actions via `gh api` (the same data Homey's release train acts on):
  #   * batch CI  = workflow runs on batch/** branches whose head contains the PR head
  #   * deploys   = main-branch runs of the repo's "Deploy…" workflow whose head
  #                 contains the PR's merge commit
  # Repo-wide lookups are shared through Rails.cache with a short TTL; the result
  # per PR lands in StatusCache (Redis) via the watcher, so rendering never calls gh.
  #
  # The REST budget (5,000 requests an hour) is shared with Homey and every other gh
  # caller on this account, so this class asks as little as it can:
  #   * "does commit A contain commit B" never changes, so the answer is kept in Redis
  #     (it survives a watcher restart) and a PR needs at most ~3 compares, not one per run;
  #   * a call that failed is never turned into a state or cached: it raises Unavailable,
  #     and StatusCache keeps what it knew;
  #   * once GitHub says the rate limit is used up, nothing is asked until it resets.
  class Delivery
    State = Struct.new(:state, :detail, :failed, keyword_init: true) do
      def live? = state == "live"
    end

    # GitHub could not be asked (outage, rate limit, gh missing). Never a delivery state.
    Unavailable = Class.new(StandardError)

    RUNS_TTL = 60.seconds
    CONTAINS_TTL = 30.days.to_i
    MISSING_TTL = 1.hour.to_i # a compare GitHub answered 404/422 (a commit it no longer has)
    PAUSE_KEY = "#{RunState::PREFIX}:gh:rate-limited".freeze
    PAUSE_FALLBACK = 5.minutes.to_i
    RATE_LIMITED = /rate limit/i
    NOT_FOUND = /HTTP 4(04|22)/
    WORKFLOWS_TTL = 1.hour
    DEPLOY_NAME = /\Adeploy/i

    # What the Releases page needs to know about a repo, kept in Redis next to the
    # per-PR state: its Deploy workflow (nil = none) and that workflow's latest main run.
    Summary = Struct.new(:repo, :workflow, :run, :at, keyword_init: true) do
      def workflow? = workflow.present?

      def run_state
        return if run.blank?
        return "running" if run["status"] != "completed"

        run["conclusion"] == "success" ? "success" : "failed"
      end

      def run_at = run.presence && Time.zone.parse(run["created_at"].to_s)
      def run_url = run.presence && run["html_url"]
    end
    SUMMARY_TTL = 3.days.to_i

    def self.summary_key(repo) = "#{RunState::PREFIX}:release:#{repo}"
    def self.contains_key(repo, base, head) = "#{RunState::PREFIX}:contains:#{repo}:#{base}:#{head}"

    # When the rate-limit pause ends (a Time), or nil when GitHub may be asked.
    def self.paused_until
      raw = RunState.redis.get(PAUSE_KEY) or return
      Time.zone.parse(raw)
    rescue ArgumentError, Redis::BaseError
      nil
    end

    # Cached repo summary, or nil when the watcher has not looked at this repo yet.
    def self.summary(repo)
      raw = RunState.redis.get(summary_key(repo)) or return
      h = JSON.parse(raw)
      Summary.new(repo: repo, workflow: h["workflow"], run: h["run"], at: h["at"])
    rescue JSON::ParserError, Redis::BaseError
      nil
    end

    # persist: keep "does this commit contain that one" answers in Redis (on for the
    # real gh; a fake runner in tests answers differently for the same pair).
    def initialize(runner: nil, persist: runner.nil?)
      @runner = runner || method(:gh)
      @persist = persist
    end

    # nil = nothing to say (no batch run for it, and no deploy workflow or not merged).
    # Raises Unavailable when GitHub could not be asked; the caller keeps what it had.
    def compute(pr)
      repo = pr&.repo
      return if repo.blank?

      state = (pr.merged? && deploy_state(repo, pr)) || batch_state(repo, pr)
      remember(repo) if pr.merged?
      state
    end

    # Store the repo summary (Deploy workflow + its latest run). Called from compute, so
    # the watcher's status refresh keeps it current; also by `rails work_queue:refresh_delivery`.
    # Skipped when GitHub could not be asked, so an outage never reads as "no workflow".
    def remember(repo)
      workflow = deploy_workflow(repo)
      return unless @workflows_ok

      run = workflow && deploy_runs(repo, workflow["id"]).first
      body = { workflow: workflow&.dig("name"), at: Time.current.iso8601,
               run: run&.slice("status", "conclusion", "created_at", "html_url", "head_sha") }
      RunState.redis.set(self.class.summary_key(repo), body.to_json, ex: SUMMARY_TTL)
      self.class.summary(repo)
    rescue Redis::BaseError
      nil
    end

    # Deploy button: dispatches the repo's own "Deploy…" GitHub Actions workflow on
    # main (the same workflow this class tracks). Never deploys anything else.
    # => [ok, message]
    def deploy(pr, ref: "main")
      return [false, "PR is not merged yet"] unless pr&.merged?

      deploy_repo(pr.repo, ref: ref)
    end

    # One dispatch for the whole repo (the Releases page): everything merged to main goes out.
    def deploy_repo(repo, ref: "main")
      workflow = deploy_workflow(repo) or return [false, "#{repo} has no active Deploy workflow"]
      out, ok, err = @runner.call("workflow", "run", workflow["id"].to_s, "--ref", ref, "-R", repo)
      Rails.cache.delete(["wq-deploy-runs", repo, workflow["id"]])
      [ok, ok ? "Started #{workflow['name']} on #{ref}" : "gh workflow run failed: #{(out.presence || err).to_s.strip.truncate(160)}"]
    rescue Unavailable => e
      [false, "GitHub could not be asked: #{e.message}"]
    end

    private

    def batch_state(repo, pr)
      return if pr.head_sha.blank?

      batches = runs(repo).select { |r| r["head_branch"].to_s.start_with?("batch/") }
      # A merged PR can only read "testing" here, so finished batches need no compare.
      batches = batches.reject { |r| r["status"] == "completed" } if pr.merged?
      run = batches.find { |r| contains?(repo, pr.head_sha, r["head_sha"]) }
      return unless run

      if run["status"] != "completed"
        State.new(state: "testing", detail: "Testing together on #{run['head_branch']} (#{run['name']}).")
      elsif !pr.merged? && failed?(run)
        State.new(state: "ci_failed", detail: "Batch CI failed on #{run['head_branch']}.", failed: [run["name"]])
      end
    end

    MAIN = %w[main master].freeze
    MAX_STACK = 4
    PARENT_FIELDS = "number,state,baseRefName,headRefName,url,headRefOid,mergeCommit,mergedAt".freeze

    def deploy_state(repo, pr, depth = 0)
      workflow = deploy_workflow(repo) or return
      return stacked_state(repo, pr, workflow, depth) if pr.base.present? && MAIN.exclude?(pr.base)

      sha = pr.merge_sha.presence || pr.head_sha
      case deployed(repo, sha, deploy_runs(repo, workflow["id"]))
      when :live then State.new(state: "live", detail: "Deployed by #{workflow['name']}.")
      when :deploying then State.new(state: "deploying", detail: "#{workflow['name']} is running with this change.")
      when :failed then State.new(state: "deploy_failed", detail: "#{workflow['name']} failed with this change.", failed: [workflow["name"]])
      else batch_state(repo, pr) || State.new(state: "not_live", detail: "Merged; no #{workflow['name']} run includes it yet.")
      end
    end

    # Where `sha` is among main's deploy runs (newest first), in a few compares instead of one
    # per run. main only moves forward, so each run's head contains every older run's head:
    #   live      the newest green run contains it (if that one doesn't, no older green one does)
    #   deploying a run still going contains it
    #   failed    the newest finished run after that green one contains it, and it wasn't green
    def deployed(repo, sha, runs)
      green = runs.find { |r| r["conclusion"] == "success" }
      return :live if green && contains?(repo, sha, green["head_sha"])
      return :deploying if runs.any? { |r| r["status"] != "completed" && contains?(repo, sha, r["head_sha"]) }

      since_green = green ? runs.take_while { |r| !r.equal?(green) } : runs
      newest = since_green.find { |r| r["status"] == "completed" }
      :failed if newest && contains?(repo, sha, newest["head_sha"])
    end

    # A PR merged into another branch (a stacked or bundle PR) is not on main: a deploy of
    # main does not ship it, and with squash merges its own merge commit never reaches main
    # at all. Its fate is that of the PR that carries its base branch: follow that one.
    # "stacked" = merged, but the branch it went into has not been merged to main yet.
    def stacked_state(repo, pr, workflow, depth)
      parent = depth < MAX_STACK ? base_pr(repo, pr.base) : nil
      if parent.nil?
        State.new(state: "stacked", detail: "Merged into #{pr.base}, which has no pull request to main yet. A deploy of main would not include it.")
      elsif parent.merged?
        state = deploy_state(repo, parent, depth + 1) or return
        State.new(state: state.state, failed: state.failed, detail: "Went to main inside PR ##{parent.number} (#{pr.base}). #{state.detail}")
      elsif parent.open?
        State.new(state: "stacked", detail: "Merged into #{pr.base}; waiting for PR ##{parent.number} to merge that branch to main.")
      else
        State.new(state: "stacked", detail: "Merged into #{pr.base}, but PR ##{parent.number} for that branch was closed without merging.")
      end
    end

    # The PR whose head is this branch (merged one first, then open, then whatever exists).
    def base_pr(repo, branch)
      list = Rails.cache.fetch(["wq-base-pr", repo, branch], expires_in: RUNS_TTL) do
        out, ok, err = @runner.call("pr", "list", "-R", repo, "--head", branch, "--state", "all", "--limit", "10", "--json", PARENT_FIELDS)
        raise Unavailable, "gh pr list failed: #{err.to_s.strip.truncate(120)}" unless ok

        JSON.parse(out)
      end
      j = Array(list).min_by { |p| %w[MERGED OPEN].index(p["state"]) || 2 } or return
      PullRequests::Status.new(url: j["url"], number: j["number"], state: j["state"], base: j["baseRefName"], head: j["headRefName"],
                               head_sha: j["headRefOid"], merge_sha: j.dig("mergeCommit", "oid"), merged_at: j["mergedAt"])
    rescue JSON::ParserError
      raise Unavailable, "gh pr list answered something unreadable"
    end

    def failed?(run) = %w[failure timed_out cancelled startup_failure].include?(run["conclusion"])

    def runs(repo)
      Rails.cache.fetch(["wq-runs", repo], expires_in: RUNS_TTL) do
        api("repos/#{repo}/actions/runs?per_page=50")&.fetch("workflow_runs", []) || []
      end
    end

    def deploy_workflow(repo)
      found = Rails.cache.fetch(["wq-deploy-wf2", repo], expires_in: WORKFLOWS_TTL) do
        list = api("repos/#{repo}/actions/workflows")&.fetch("workflows", nil)
        # A failed lookup raises Unavailable, or yields nil when GitHub has no such repo; neither
        # is cached, so it is retried rather than read as "no workflow".
        list && { "wf" => list.find { |w| w["state"] == "active" && w["name"].to_s.match?(DEPLOY_NAME) }&.slice("id", "name") }
      end
      @workflows_ok = !found.nil?
      found&.dig("wf")
    end

    def deploy_runs(repo, id)
      Rails.cache.fetch(["wq-deploy-runs", repo, id], expires_in: RUNS_TTL) do
        api("repos/#{repo}/actions/workflows/#{id}/runs?branch=main&per_page=20")&.fetch("workflow_runs", []) || []
      end
    end

    # Does commit `head` contain commit `base`? Two SHAs never change their relation, so the
    # answer lives in Redis for a month: a watcher restart costs no GitHub calls. Only an answer
    # GitHub gave is kept; a failed call raises Unavailable and is asked again next time.
    def contains?(repo, base, head)
      return false if base.blank? || head.blank?
      return true if base == head

      key = self.class.contains_key(repo, base, head)
      known = kept(key)
      return known == "1" unless known.nil?

      status = api("repos/#{repo}/compare/#{base}...#{head}")&.dig("status")
      answer = %w[ahead identical].include?(status)
      keep(key, answer ? "1" : "0", status ? CONTAINS_TTL : MISSING_TTL)
      answer
    end

    def kept(key)
      return unless @persist

      RunState.redis.get(key)
    rescue Redis::BaseError
      nil
    end

    def keep(key, value, ttl)
      return unless @persist

      RunState.redis.set(key, value, ex: ttl)
    rescue Redis::BaseError
      nil
    end

    # One REST read: the parsed body, or nil when GitHub answered that the thing does not exist
    # (404/422). Anything else that went wrong raises Unavailable, and while the rate limit is
    # used up it raises without calling GitHub at all.
    def api(path)
      if (till = self.class.paused_until)
        raise Unavailable, "GitHub rate limit used up until #{till.strftime('%H:%M')}"
      end

      out, ok, err = @runner.call("api", path)
      return JSON.parse(out) if ok

      said = "#{err} #{out}"
      return nil if said.match?(NOT_FOUND)

      pause! if said.match?(RATE_LIMITED)
      raise Unavailable, "gh api #{path} failed: #{err.to_s.strip.truncate(120)}"
    rescue JSON::ParserError
      raise Unavailable, "gh api #{path} answered something unreadable"
    end

    # GitHub said the hourly limit is used up: ask nothing more until it resets. The reset time
    # comes from /rate_limit, which never counts against the limit.
    def pause!
      out, ok = @runner.call("api", "rate_limit", "--jq", ".resources.core.reset")
      left = (ok ? out.to_s.strip.to_i : 0) - Time.current.to_i
      seconds = left.between?(1, 3600) ? left + 5 : PAUSE_FALLBACK
      till = Time.current + seconds
      RunState.redis.set(PAUSE_KEY, till.iso8601, ex: seconds)
      Rails.logger.warn("[work-queue] GitHub rate limit used up: no gh api calls until #{till.strftime('%H:%M:%S')}")
    rescue Redis::BaseError
      nil
    end

    # => [stdout, ok, stderr]
    def gh(*args)
      return ["", false, "gh CLI not found"] unless PullRequests.gh?

      out, err, status = Open3.capture3("gh", *args)
      [out, status.success?, err]
    rescue SystemCallError => e
      ["", false, e.message]
    end
  end
end
