require "json"

# Auto-merges related still-pending board items into one. Called from
# InstantTriageJob after a new pending item is triaged. Detection is a cheap Haiku
# call (stubbed in tests); merging folds the group into the OLDEST item as primary,
# appends each secondary's content to the primary, and sets merged_into_id on the
# secondaries so they drop off the board. Reversible via the Unmerge action.
module Board
  module Consolidator
    module_function

    MODEL      = "claude-haiku-4-5-20251001".freeze
    MAX_TOKENS = 128

    SYSTEM_PROMPT = <<~SYS.strip
      You decide which existing backlog items describe the SAME work as a new item.
      Reply with ONLY valid JSON: {"duplicates":[<1-based indices of the same work>]}.
      Be conservative — include an index only if it is clearly the same task, not
      merely related. Empty list if none.
    SYS

    # Entry point. Merges `task` with any pending siblings the detector flags.
    def run!(task)
      return unless task&.board_state == "pending" && task.merged_into_id.nil?
      candidates = task.project.tasks
                       .where(board_state: "pending", merged_into_id: nil)
                       .where.not(id: task.id).order(:created_at).to_a
      return if candidates.empty?

      related_ids = Array(detect_related(task, candidates)).map(&:to_s)
      group = [task] + candidates.select { |c| related_ids.include?(c.id.to_s) }
      return if group.size < 2

      merge!(group)
    end

    # Fold a group into the oldest item. Returns the primary.
    def merge!(group)
      group = group.uniq
      primary = group.min_by(&:created_at)
      secondaries = group - [primary]
      return primary if secondaries.empty?

      Task.transaction do
        appended = secondaries.map do |s|
          s.update!(merged_into_id: primary.id)
          "- **#{s.title}**#{s.description.present? ? "\n  #{s.description.to_s.truncate(500)}" : ''}"
        end
        merged_block = "\n\n## Merged sub-items\n#{appended.join("\n")}"
        primary.update!(description: "#{primary.description}#{merged_block}".strip)
      end
      primary.emit_worklog("board.consolidated", status: "info",
        label: "Merged #{secondaries.size} related item(s)",
        payload: { merged_ids: secondaries.map(&:id) })
      primary
    end

    # Haiku: which candidates are the same work as `task`? Returns an array of ids.
    def detect_related(task, candidates)
      api_key = ENV["ANTHROPIC_API_KEY"].to_s.strip
      return [] if api_key.blank?

      listing = candidates.each_with_index.map do |c, i|
        "#{i + 1}. #{c.title}#{c.description.present? ? " — #{c.description.to_s.truncate(160)}" : ''}"
      end.join("\n")
      user = "New item:\n#{task.title}#{task.description.present? ? " — #{task.description.to_s.truncate(300)}" : ''}\n\n" \
             "Existing pending items:\n#{listing}"

      client = Anthropic::MessagesClient.new(api_key: api_key)
      raw = client.complete(model: MODEL, max_tokens: MAX_TOKENS, system: SYSTEM_PROMPT, user: user)
      text = raw.to_s.strip.sub(/\A```(?:json)?\s*/i, "").sub(/```\s*\z/, "")
      idx = Array(JSON.parse(text)["duplicates"]).map(&:to_i)
      idx.filter_map { |n| candidates[n - 1]&.id if n.positive? }
    rescue Anthropic::Error, JSON::ParserError => e
      Rails.logger.warn("[consolidator] #{task.id}: #{e.class}: #{e.message}")
      []
    end
  end
end
