module WorkQueue
  # Moves items on when their PR moves on GitHub without myjira doing it, chiefly when
  # homey's release train (HomeyTrain) tests and merges it:
  #
  #   * merged  the PR is MERGED (the train fast-forwarded main, or someone merged it on
  #             GitHub): the item is done, so Releases lists it as ready to deploy.
  #   * red     a PR in a repo homey batches failed a batch on its own (homey's culprit
  #             record, or a failed check on its head, which homey reports as a commit status):
  #             the item is blocked with the failing checks and a link, never left waiting.
  #
  # Called by the watcher after each status refresh. It only reads what that refresh put in
  # StatusCache plus homey's Redis, so it asks GitHub nothing.
  class TrainSync
    def initialize(writer: QueueWriter.new, failure: HomeyTrain.method(:failure), batched: HomeyTrain.method(:batched?))
      @writer = writer
      @failure = failure
      @batched = batched
    end

    # Returns the items it changed.
    def call(items)
      items.select { |i| i.pr.present? && (i.status == "review" || train_blocked?(i)) }.filter_map do |item|
        pr = StatusCache.pr(item.pr) or next
        if pr.merged?
          merged(item, pr)
        elsif item.status == "review" && pr.open? && @batched.call(pr.repo) && (failure = failure_for(pr))
          blocked(item, pr, failure)
        end
      rescue ArgumentError, SystemCallError
        next # the item vanished from its queue file
      end
    end

    private

    def train_blocked?(item) = item.status == "blocked" && item.bundle_info["train"].present?

    def merged(item, pr)
      by = @batched.call(pr.repo) ? " by homey's release train" : " on GitHub"
      @writer.update(item.slug, item.n, log: "PR ##{pr.number} merged#{by}; ready to deploy") do |i|
        i["status"] = "done"
        i["bundle"].delete("train") if i["bundle"].is_a?(Hash)
      end
      item
    end

    def blocked(item, pr, failure)
      checks = failure.checks.presence || ["release-train batch"]
      @writer.update(item.slug, item.n, log: "Failed on homey's release train: #{failure.note}. Failing: #{checks.join(', ')}. #{failure.url}") do |i|
        i["status"] = "blocked"
        i["bundle"] = (i["bundle"].is_a?(Hash) ? i["bundle"] : {}).merge("train" => { "checks" => checks, "url" => failure.url, "sha" => pr.head_sha })
      end
      item
    end

    # homey's own culprit record when its Redis can be read; otherwise a failed check on the
    # PR's head (repos homey batches run no CI per PR, so a red check there is the train's).
    def failure_for(pr)
      @failure.call(pr.repo, pr.number, pr.head_sha) || (
        HomeyTrain::Failure.new(number: pr.number, checks: pr.failed_checks, url: "#{pr.url}/checks",
                                note: "PR ##{pr.number} has failed checks at #{pr.head_sha.to_s.first(7)}") if pr.failed_checks?
      )
    end
  end
end
