module WorkQueue
  # A parent that only groups its child steps (no branch, no PR of its own) has
  # nothing to merge once every child is finished: each child shipped in its own PR.
  # The watcher hands every queue change of a project to #call, which closes such
  # parents instead of leaving them "Ready for review" for the person.
  class ParentCloser
    FINISHED = %w[done merged dropped].freeze

    def initialize(writer: QueueWriter.new)
      @writer = writer
    end

    # Every child step is finished and at least one was actually done.
    def self.children_done?(kids) = kids.any? && kids.all? { |k| FINISHED.include?(k.status) } && kids.any? { |k| k.status == "done" }

    # A grouping parent: in review with nothing of its own to merge or bundle.
    def self.grouping?(item)
      item.status == "review" && item.pr.blank? && item.branch.blank? && !item.ready_to_bundle? &&
        !item.yours? && item.open_questions.empty?
    end

    # Returns the items it closed.
    def call(items)
      kids = items.group_by(&:parent)
      items.select { |i| self.class.grouping?(i) && self.class.children_done?(Array(kids[i.n]).reject { |k| k.n == i.n }) }.each do |item|
        @writer.set_status(item.slug, item.n, "done", log: "Closed by itself: every child step is done and this task has no branch or PR of its own")
      end
    end
  end
end
