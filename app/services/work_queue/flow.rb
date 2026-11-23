module WorkQueue
  # Plain-words view of an item for the Flow layout: a tone (dot colour), a
  # label, a step on the six-step path, and the filter tags it belongs to.
  #
  # Some filters have no real data source yet and map to the nearest status:
  #   testing  = running in the router's "review" phase (no CI / "test together" feed)
  #   ok/Live  = status done (PR merged; no deploy check)
  class Flow
    STEPS = ["Asked", "Planned", "Building", "Review", "Testing together", "Live"].freeze
    FILTERS = [
      ["all", "All"], ["you", "Needs you"], ["answer", "Needs answer"], ["approve", "Needs approval"],
      ["merge", "Ready to merge"], ["run", "In progress"], ["testing", "Testing / deploying"], ["bad", "Failed"],
      ["wait", "Queued"], ["ok", "Live"], ["open", "Not live yet"], ["closed", "Merged / dropped"]
    ].freeze

    YOUR_PART = {
      "answer" => "Answer the questions above.",
      "approve" => "Approve the plan or ask for changes.",
      "merge" => "Look at the changes and merge the PR.",
      "review" => "Look at the changes; there is no PR to merge yet.",
      "bad" => "Check the log below, then retry or tell the agent what to do.",
      "run" => "Nothing yet. It moves on by itself.",
      "wait" => "Nothing. It starts by itself.",
      "ok" => "Nothing.",
      "closed" => "Nothing."
    }.freeze

    attr_reader :item, :tone, :label, :step, :tags

    def initialize(item, context = nil)
      @item = item
      @context = context
      @tone, @label, @step, tags, @part = compute
      @tags = item.open? ? ["all", "open", *tags].uniq : tags
    end

    def closed? = tags.include?("closed")
    def your_part = YOUR_PART.fetch(@part)
    def happening = item.summary.presence || item.log.last&.dig("text").presence || "Nothing recorded yet."

    # Per step: "done", "now-<tone>" or nil (not reached).
    def path
      STEPS.each_index.map do |i|
        if i < step || (i == step && tone == "ok") then "done"
        elsif i == step && tone != "wait" then "now-#{tone}"
        end
      end
    end

    def ref
      parts = ["task #{item.n}"]
      parts << "PR ##{item.pr_number}" if item.pr_number
      parts << "branch #{item.branch}" if item.branch.present?
      parts.join(" · ")
    end

    private

    def compute
      case item.status
      when "merged" then ["wait", item.merged_into ? "Folded into task #{item.merged_into}" : "Folded into another task", 0, %w[closed], "closed"]
      when "dropped" then ["wait", "Dropped", 0, %w[closed], "closed"]
      when "done" then ["ok", "Live", 5, %w[ok], "ok"]
      else open_state
      end
    end

    def open_state
      return ["you", "Needs your answer", item.status == "review" ? 3 : 1, %w[you answer], "answer"] if item.open_questions.any?
      return ["you", "Needs your approval", 1, %w[you approve], "approve"] if item.awaiting_approval

      case item.status
      when "triage" then ["wait", "Being sorted", 0, %w[wait], "wait"]
      when "queued" then ["wait", "Queued", 0, %w[wait], "wait"]
      when "running" then running_state
      when "blocked" then ["bad", "Stuck: needs a look", 2, %w[bad you], "bad"]
      else review_state
      end
    end

    def running_state
      case @context&.run&.dig("phase")
      when "plan" then ["run", "Planning", 1, %w[run], "run"]
      when "review" then ["run", "Testing", 4, %w[testing], "run"]
      else ["run", "Building", 2, %w[run], "run"]
      end
    end

    def review_state
      return ["you", "Ready for review", 3, %w[you], "review"] if item.pr.blank?

      pr = @context&.pr_status
      return ["bad", "PR has conflicts", 3, %w[bad you], "bad"] if pr&.conflicts?

      ["you", "Ready to merge", 3, %w[you merge], "merge"]
    end
  end
end
