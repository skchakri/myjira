# A single cross-project review queue: every `in_review` board item across all
# active projects, grouped by project, carrying the same PR/plan links and
# Approve & merge / Reject actions the board offers. Lets the user work one
# review queue instead of opening each project's board in turn.
class ReviewsController < ApplicationController
  def index
    items = Task.where(board_state: "in_review")
                .includes(:project) # avoid N+1 on item.project in the partial
                .order("projects.name ASC", Arel.sql("tasks.updated_at DESC"))
                .references(:project)
    # Mirror the sidebar: only surface active folders; archived items stay
    # reachable on their own board.
    @groups = items.select { |t| t.project&.archived_at.nil? }
                   .group_by(&:project)
                   .sort_by { |project, _| project.name.downcase }
  end
end
