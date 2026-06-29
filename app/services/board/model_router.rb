# Cost-aware model auto-routing for board pipeline launches.
#
# Picks a concrete Claude tier (haiku|sonnet|opus) from cheap, already-present
# signals on the item so simple work runs on Haiku and risky/hard work escalates
# to Opus — instead of every board launch using the static "default" slot. This
# is a *pure function* of existing fields: no DB writes, no network, no mutation.
# It only fires for board pipeline steps (Board::Pipeline.launch_step!); human
# per-playbook / non-board launches keep their chosen model, so a manual override
# still wins by construction.
#
# Mirrors ModelPricing's module style.
module Board
  module ModelRouter
    module_function

    # Description longer than this (chars) reads as a meaty, multi-part task → Opus.
    LONG_DESCRIPTION = 1200
    # Short answer/ask work below this length is cheap enough for Haiku.
    SHORT_DESCRIPTION = 400
    # Labels that signal multi-file / high-complexity work → Opus.
    OPUS_LABELS = %w[multi-file complex refactor architecture migration].freeze

    # => "haiku" | "sonnet" | "opus". Order matters: escalate to Opus first, then
    # consider Haiku for cheap work, else fall back to Sonnet (safe middle).
    def pick(task:, step:)
      return "opus"  if escalate?(task)
      return "haiku" if cheap?(task, step)

      "sonnet"
    end

    # Hard/risky signals: urgent, already failed at least once, a big description,
    # or a complexity label.
    def escalate?(task)
      task.priority.to_s == "urgent" ||
        task.autopilot_attempts.to_i >= 1 ||
        task.description.to_s.length > LONG_DESCRIPTION ||
        (Array(task.labels).map(&:to_s) & OPUS_LABELS).any?
    end

    # Cheap signals: an answer-only step, or a short "ask" item. Callers only reach
    # here once escalate? is false, so this never overrides an Opus decision.
    def cheap?(task, step)
      step.to_s == "answer" ||
        (task.item_type.to_s == "ask" && task.description.to_s.length < SHORT_DESCRIPTION)
    end
  end
end
