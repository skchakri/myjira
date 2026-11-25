module WorkQueue
  # Does an item's next step need a real browser (Claude-in-Chrome)? Either the
  # person flagged it ("browser" = "1" in the item's RunState hash, set from the
  # detail pane) or its text reads like a browser step. Detection is a plain
  # keyword scan over title, description, summary and recent log lines.
  module BrowserStep
    module_function

    FLAG = "browser".freeze
    PATTERNS = [
      /\bchrome\b/i, /\bbrowser\b/i, %r{\bopen\s+(?:https?://|www\.)\S+}i,
      /\b(?:upload|submit|log\s?in|sign\s?in)\b[^.\n]{0,40}\b(?:portal|console|dashboard)\b/i,
      %r{\b(?:developers\.tiktok|tiktok\s+(?:developer|portal)|youtube\s+studio|studio\.youtube|instagram|
         developers\.facebook|business\.facebook|play\.google\.com/console|appstoreconnect)}xi
    ].freeze

    # :flag, :step (an open plan step has browser: true), :detected, or nil.
    def reason(item, run = RunState.get(item.key))
      return :flag if run[FLAG] == "1"
      return nil if run[FLAG] == "0" # the person said no: ignore detection

      return :step if item.respond_to?(:browser_step) && item.browser_step

      :detected if detect?(text_for(item))
    end

    def needed?(item, run = RunState.get(item.key)) = reason(item, run).present?

    def detect?(text) = PATTERNS.any? { |re| re.match?(text.to_s) }

    def text_for(item)
      logs = Array(item.log).last(5).map { |l| l.is_a?(Hash) ? l["text"] || l["msg"] : l }
      [item.title, item.description, item.summary, *logs].compact.join("\n")
    end
  end
end
