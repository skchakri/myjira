module WorkQueue
  # Everything that needs the person, across every project's queue, in one list:
  # sectioned, oldest first, each entry with how long it has waited. Built from the
  # queue files plus the cached run / PR state (Flow + ItemContext); never runs git or gh.
  class Inbox
    # key, section title, word for the summary ("6 decisions").
    SECTIONS = [
      ["decisions", "Decisions", "decision"],
      ["permissions", "Permission prompts", "permission prompt"],
      ["approve", "Needs approval", "to approve"],
      ["review", "Ready to review or merge", "to review"],
      ["stalled", "Stalled", "stalled"],
      ["failed", "Failed", "failed"]
    ].freeze
    COUNTED = %w[decisions permissions].freeze
    COUNT_CACHE = "work_queue/inbox/counts".freeze

    Entry = Struct.new(:item, :context, :flow, :section, keyword_init: true) do
      def key = item.key
      def dom_id = "inbox_#{item.slug}_#{item.n}"
      def since = flow.waiting_since
      # Changes when what is asked changes, so an "answered" row re-opens for a new question.
      def signature = [section, item.open_questions.size, item.status].join("/")
    end

    def initialize(store: Store.new)
      @store = store
    end

    def entries
      @entries ||= @store.all.filter_map { |item| entry_for(item) }
                         .sort_by { |e| [e.since || Time.current, e.item.slug, e.item.n] }
    end

    # [[key, title, [Entry]]] for the sections that have entries, in display order.
    def sections
      by = entries.group_by(&:section)
      SECTIONS.filter_map { |key, title, _| [key, title, by[key]] if by[key] }
    end

    def counts = @counts ||= SECTIONS.to_h { |key, _, _| [key, entries.count { |e| e.section == key }] }
    def total = entries.size
    def overdue = entries.count { |e| e.flow.waiting_level == "late" }
    def empty? = entries.empty?

    # Open permission prompts (questions, not items): what the person actually clicks through.
    def permission_prompts
      entries.sum { |e| e.item.open_questions.count { |q| PermissionRules.permission_question?(q.q) } }
    end

    # [[anchor, "6 decisions"]] for the strip at the top of the page and the morning summary.
    def summary
      parts = SECTIONS.filter_map do |key, _, word|
        n = key == "permissions" ? permission_prompts : counts[key]
        [key, "#{n} #{COUNTED.include?(key) ? word.pluralize(n) : word}"] if n.positive?
      end
      parts << ["oldest", "#{overdue} waiting over 3 days"] if overdue.positive?
      parts
    end

    def summary_line = empty? ? "Nothing needs you." : summary.map(&:last).join(" · ")

    # { "total" => n, "overdue" => n } for the sidebar, cached briefly: it renders on every page.
    def self.counts
      Rails.cache.fetch(COUNT_CACHE, expires_in: 30.seconds) do
        inbox = new
        { "total" => inbox.total, "overdue" => inbox.overdue }
      end
    rescue StandardError => e
      Rails.logger.warn("[inbox] counts failed: #{e.class}: #{e.message}")
      { "total" => 0, "overdue" => 0 }
    end

    private

    def entry_for(item)
      return unless ItemContext.wanted?(item)

      context = ItemContext.new(item, store: @store)
      flow = context.flow
      return unless flow.tags.include?("you")

      Entry.new(item: item, context: context, flow: flow, section: section_for(item, flow))
    end

    def section_for(item, flow)
      open = item.open_questions
      if open.any?
        open.all? { |q| PermissionRules.permission_question?(q.q) } ? "permissions" : "decisions"
      elsif item.awaiting_approval then "approve"
      elsif flow.stalled? then "stalled"
      elsif flow.tone == "bad" then "failed"
      else "review"
      end
    end
  end
end
