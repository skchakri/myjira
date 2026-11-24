module WorkQueue
  # One project's block in the task list: which items to draw, in what order, and
  # the numbers in its title bar.
  #
  # A project can hold hundreds of finished items, so by default only the work that
  # is still going is drawn: open items, anything still testing / deploying / failed,
  # the finished parents above them (so the tree stays connected), the selected item,
  # and the few most recently finished top-level tasks. The rest ("older") load on
  # demand with all: true. Progress and the counts always cover every item.
  class Listing
    RECENT_CLOSED = 5
    # Tones that mean "not finished", whatever the queue status says.
    ACTIVE_TONES = %w[run you bad].freeze

    attr_reader :slug, :items, :contexts, :flows, :progress

    def initialize(slug, items, store: Store.new, selected: nil, all: false)
      @slug = slug
      @items = items
      @all = all
      @selected = selected.to_s.split(":", 2).then { |s, n| s == slug ? n.to_i : nil }
      @contexts = items.to_h { |i| [i.key, ItemContext.wanted?(i) ? ItemContext.new(i, store: store) : nil] }
      @flows = items.to_h { |i| [i.key, @contexts[i.key]&.flow || Flow.new(i)] }
      @progress = Progress.new(items, flows: @flows, store: store)
      @by_n = items.index_by(&:n)
    end

    def all? = @all

    # How many items the default view leaves out (the same number whether or not
    # they are drawn right now).
    def older_count = @older_count ||= items.size - default_shown.size

    # A finished task whose child steps are still open stays up with the open work.
    def sorted
      @sorted ||= begin
        order = Store::DISPLAY_ORDER
        items.sort_by { |i| [i.open? || progress.for(i).active ? 0 : 1, order.index(i.display_status) || 9, -i.n] }
      end
    end

    # Item numbers that are drawn.
    def shown
      @shown ||= @all ? items.to_set(&:n) : default_shown
    end

    def visible = @visible ||= sorted.select { |i| shown.include?(i.n) }

    # { parent n (nil for top level) => [items] }, drawn items only.
    def children
      @children ||= visible.group_by { |i| i.parent && i.parent != i.n && shown.include?(i.parent) ? i.parent : nil }
    end

    # True totals per filter tag, over every item (drawn or not).
    def counts = @counts ||= flows.values.flat_map(&:tags).tally

    def live = @live ||= flows.values.reject(&:closed?)
    def need = live.count { |f| f.tags.include?("you") }
    def failed = live.count { |f| f.tone == "bad" }
    def open_count = items.count(&:open?)
    def done_count = flows.values.count(&:finished?)

    private

    def active?(item) = item.open? || ACTIVE_TONES.include?(flows[item.key].tone)

    def default_shown
      keep = Set.new
      items.each { |i| with_ancestors(i, keep) if active?(i) }
      with_ancestors(@by_n[@selected], keep) if @selected && @by_n[@selected]
      recent = items.reject { |i| keep.include?(i.n) || (i.parent && i.parent != i.n && @by_n.key?(i.parent)) }
      recent.max_by(RECENT_CLOSED) { |i| i.updated_at.to_f }.each { |i| keep << i.n }
      keep
    end

    # The item and every parent above it (a parent cycle is walked once).
    def with_ancestors(item, keep)
      cur = item
      while cur && keep.add?(cur.n)
        cur = @by_n[cur.parent]
      end
    end
  end
end
