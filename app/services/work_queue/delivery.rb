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
  class Delivery
    State = Struct.new(:state, :detail, :failed, keyword_init: true) do
      def live? = state == "live"
    end

    RUNS_TTL = 30.seconds
    WORKFLOWS_TTL = 1.hour
    DEPLOY_NAME = /\Adeploy/i

    def initialize(runner: method(:gh))
      @runner = runner
    end

    # nil = nothing to say (no batch run for it, and no deploy workflow or not merged).
    def compute(pr)
      repo = pr&.repo
      return if repo.blank?

      (pr.merged? && deploy_state(repo, pr)) || batch_state(repo, pr)
    end

    private

    def batch_state(repo, pr)
      return if pr.head_sha.blank?

      run = runs(repo).select { |r| r["head_branch"].to_s.start_with?("batch/") }
                      .find { |r| contains?(repo, pr.head_sha, r["head_sha"]) }
      return unless run

      if run["status"] != "completed"
        State.new(state: "testing", detail: "Testing together on #{run['head_branch']} (#{run['name']}).")
      elsif !pr.merged? && failed?(run)
        State.new(state: "ci_failed", detail: "Batch CI failed on #{run['head_branch']}.", failed: [run["name"]])
      end
    end

    def deploy_state(repo, pr)
      workflow = deploy_workflow(repo) or return
      sha = pr.merge_sha.presence || pr.head_sha
      containing = deploy_runs(repo, workflow["id"]).select { |r| contains?(repo, sha, r["head_sha"]) }
      if containing.any? { |r| r["conclusion"] == "success" }
        State.new(state: "live", detail: "Deployed by #{workflow['name']}.")
      elsif containing.any? { |r| r["status"] != "completed" }
        State.new(state: "deploying", detail: "#{workflow['name']} is running with this change.")
      elsif containing.any?
        State.new(state: "deploy_failed", detail: "#{workflow['name']} failed with this change.", failed: [workflow["name"]])
      else
        batch_state(repo, pr) || State.new(state: "not_live", detail: "Merged; no #{workflow['name']} run includes it yet.")
      end
    end

    def failed?(run) = %w[failure timed_out cancelled startup_failure].include?(run["conclusion"])

    def runs(repo)
      Rails.cache.fetch(["wq-runs", repo], expires_in: RUNS_TTL) do
        api("repos/#{repo}/actions/runs?per_page=50")&.fetch("workflow_runs", []) || []
      end
    end

    def deploy_workflow(repo)
      Rails.cache.fetch(["wq-deploy-wf", repo], expires_in: WORKFLOWS_TTL) do
        list = api("repos/#{repo}/actions/workflows")&.fetch("workflows", []) || []
        list.find { |w| w["state"] == "active" && w["name"].to_s.match?(DEPLOY_NAME) }&.slice("id", "name")
      end
    end

    def deploy_runs(repo, id)
      Rails.cache.fetch(["wq-deploy-runs", repo, id], expires_in: RUNS_TTL) do
        api("repos/#{repo}/actions/workflows/#{id}/runs?branch=main&per_page=20")&.fetch("workflow_runs", []) || []
      end
    end

    # Does commit `head` contain commit `base`? Immutable, so cached for a day.
    def contains?(repo, base, head)
      return false if base.blank? || head.blank?
      return true if base == head

      Rails.cache.fetch(["wq-contains", repo, base, head], expires_in: 1.day) do
        %w[ahead identical].include?(api("repos/#{repo}/compare/#{base}...#{head}")&.dig("status"))
      end
    end

    def api(path)
      out, ok = @runner.call("api", path)
      ok ? JSON.parse(out) : nil
    rescue JSON::ParserError
      nil
    end

    def gh(*args)
      return ["", false] unless PullRequests.gh?

      out, status = Open3.capture2("gh", *args, err: File::NULL)
      [out, status.success?]
    rescue SystemCallError => e
      [e.message, false]
    end
  end
end
