module WorkQueue
  # Everything that needs the person, across every project's queue, in one list:
  # sectioned, oldest first, each entry with how long it has waited. Built from the
  # queue files plus the cached run / PR state (Flow + ItemContext); never runs git or gh.
  class Inbox
    # key, section title, word for the summary ("6 decisions").
    SECTIONS = [
      ["decisions", "Decisions", "decision"],
      ["yours", "Yours", "yours"],
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
      def errand? = section == "yours"
      # Changes when what is asked changes, so an "answered" row re-opens for a new question.
      def signature = [section, item.open_questions.size, item.status].join("/")
    end

    # A parent whose suggested (nice-to-have) or held follow-ups wait for the person's pick.
    Batch = Struct.new(:parent, :suggested, :held, keyword_init: true) do
      def key = parent.key
      def dom_id = "inbox_batch_#{parent.slug}_#{parent.n}"
      def items = suggested + held
      def since = items.filter_map(&:created_at).min
    end

    # Items of ONE project that wait on the person right now (the same test the inbox uses).
    def self.waiting_count(items, store: Store.new)
      items.count { |i| ItemContext.wanted?(i) && ItemContext.new(i, store: store).flow.tags.include?("you") }
    end

    # Follow-ups to decide, grouped under their parent.
    def self.batches_for(items)
      by_n = items.index_by(&:n)
      picked = items.select { |i| i.parent.present? && by_n.key?(i.parent) && !i.yours? && (i.to_decide? || i.held?) }
      picked.group_by(&:parent).map do |n, kids|
        Batch.new(parent: by_n[n], suggested: kids.select(&:to_decide?).sort_by(&:n), held: kids.select(&:held?).sort_by(&:n))
      end
    end

    def initialize(store: Store.new)
      @store = store
    end

    def entries
      @entries ||= all_entries.reject { |e| e.item.snoozed? }.sort_by { |e| order(e) }
    end

    # Errands put away for now; shown folded under the Yours section.
    def snoozed
      @snoozed ||= all_entries.select { |e| e.item.snoozed? }.sort_by { |e| [e.item.snoozed_until, e.item.slug, e.item.n] }
    end

    def errands = entries.select(&:errand?)
    def errands_due = errands.select { |e| e.item.due_now? }
    def errands_overdue = errands.count { |e| e.item.overdue? }
    # An unmarked item that reads like an errand (the "mark as mine?" hint shows on it).
    def hinted?(entry) = !entry.errand? && Errands.suggest?(entry.item, run: entry.context.run)

    # [[key, title, [Entry]]] for the sections that have entries, in display order.
    def sections
      by = entries.group_by(&:section)
      SECTIONS.filter_map { |key, title, _| [key, title, by[key]] if by[key] }
    end

    def batches
      @batches ||= @store.projects.values.flat_map { |items| self.class.batches_for(items) }
                         .sort_by { |b| [b.since || Time.current, b.key] }
    end

    def to_decide = batches.sum { |b| b.suggested.size }
    def held = batches.sum { |b| b.held.size }

    def counts = @counts ||= SECTIONS.to_h { |key, _, _| [key, entries.count { |e| e.section == key }] }
    # The sidebar number: everything waiting on the person, but of the errands only the
    # ones due today or overdue (the rest are a to-do list, not something to chase).
    def total = entries.count { |e| !e.errand? || e.item.due_now? } + batches.size
    def overdue = entries.count { |e| !e.errand? && e.flow.waiting_level == "late" }
    def empty? = entries.empty? && batches.empty? && snoozed.empty?

    # Open permission prompts (questions, not items): what the person actually clicks through.
    def permission_prompts
      entries.sum { |e| e.item.open_questions.count { |q| PermissionRules.permission_question?(q.q) } }
    end

    # [[anchor, "6 decisions"]] for the strip at the top of the page and the morning summary.
    def summary
      parts = SECTIONS.filter_map do |key, _, word|
        n = key == "permissions" ? permission_prompts : counts[key]
        next ["yours", "#{n} yours#{" (#{errands_overdue} overdue)" if errands_overdue.positive?}"] if key == "yours" && n.positive?

        [key, "#{n} #{COUNTED.include?(key) ? word.pluralize(n) : word}"] if n.positive?
      end
      parts << ["followups", "#{to_decide} #{'follow-up'.pluralize(to_decide)} to decide"] if to_decide.positive?
      parts << ["followups", "#{held} held"] if held.positive?
      parts << ["oldest", "#{overdue} waiting over 3 days"] if overdue.positive?
      parts
    end

    def summary_line = summary.empty? ? "Nothing needs you." : summary.map(&:last).join(" · ")

    # { "total" => n, "overdue" => n } for the sidebar, cached briefly: it renders on every page.
    def self.counts
      Rails.cache.fetch(COUNT_CACHE, expires_in: 30.seconds) do
        inbox = new
        { "total" => inbox.total, "overdue" => inbox.overdue + inbox.errands_overdue }
      end
    rescue StandardError => e
      Rails.logger.warn("[inbox] counts failed: #{e.class}: #{e.message}")
      { "total" => 0, "overdue" => 0 }
    end

    private

    def all_entries = @all_entries ||= @store.all.filter_map { |item| entry_for(item) }

    # Oldest first; errands by due date first (overdue, due today, later, no date), then age.
    def order(entry)
      due = entry.errand? ? (entry.item.due || Date.new(9999)) : Date.new(1)
      [due, entry.since || Time.current, entry.item.slug, entry.item.n]
    end

    def entry_for(item)
      return unless ItemContext.wanted?(item)

      context = ItemContext.new(item, store: @store)
      flow = context.flow
      return Entry.new(item: item, context: context, flow: flow, section: "yours") if item.errand?
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
