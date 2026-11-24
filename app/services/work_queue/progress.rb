module WorkQueue
  # How far along every item of ONE project is. An item's own percent comes from
  # its phase (Flow#percent); a parent rolls up its whole tree: the mean of its own
  # percent and every descendant's. Dropped and folded items count nowhere.
  #
  #   progress = Progress.new(items, store: store)
  #   roll = progress.for(item)   # roll.percent, roll.done, roll.total, roll.need_you
  class Progress
    # own / percent: 0..100 or nil. total / done / left: descendants that count.
    # need_you: descendants waiting on the person. active: any descendant still open.
    Roll = Struct.new(:own, :percent, :total, :done, :need_you, :active, keyword_init: true) do
      def left = total - done
      def parent? = total.positive?
      def complete? = percent == 100
    end

    def initialize(items, flows: {}, store: nil)
      @items = items
      @flows = flows.compact
      @store = store
      @kids = items.group_by(&:parent)
      @rolls = {}
    end

    # The item's Flow, built with its cached run / PR state when a store was given.
    def flow(item)
      @flows[item.key] ||= Flow.new(item, (@store && ItemContext.wanted?(item) ? ItemContext.new(item, store: @store) : nil))
    end

    def for(item) = @rolls[item.key] ||= roll(item)

    # Every item below this one, nearest first; a parent cycle is walked once.
    def descendants(item)
      seen = Set[item.n]
      queue = [item]
      found = []
      while (cur = queue.shift)
        Array(@kids[cur.n]).each do |kid|
          next unless seen.add?(kid.n)

          found << kid
          queue << kid
        end
      end
      found
    end

    private

    def roll(item)
      own = flow(item).percent
      below = descendants(item).select { |d| flow(d).percent }
      all = [own, *below.map { |d| flow(d).percent }].compact
      Roll.new(own: own, percent: all.any? ? (all.sum.to_f / all.size).round : nil,
               total: below.size, done: below.count { |d| flow(d).finished? },
               need_you: below.select { |d| flow(d).tags.include?("you") }, active: below.any?(&:open?))
    end
  end
end
