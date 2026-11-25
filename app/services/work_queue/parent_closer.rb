module WorkQueue
  # Legacy parents (from before one-item-per-task) that only group child items.
  # myjira no longer closes them by itself; these checks drive the read-only
  # "All child steps done" label and the person's own "Close task" button.
  class ParentCloser
    FINISHED = %w[done merged dropped].freeze

    # Every child step is finished and at least one was actually done.
    def self.children_done?(kids) = kids.any? && kids.all? { |k| FINISHED.include?(k.status) } && kids.any? { |k| k.status == "done" }

    # A grouping parent: in review with nothing of its own to merge or bundle.
    def self.grouping?(item)
      item.status == "review" && item.pr.blank? && item.branch.blank? && !item.ready_to_bundle? &&
        !item.yours? && item.open_questions.empty?
    end
  end
end
