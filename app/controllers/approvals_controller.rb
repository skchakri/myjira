# A single cross-project approvals inbox: every board item parked waiting on the
# human — split into "needs your input" (the agent asked questions) and "awaiting
# approval" (a plan is ready) — with the same answer / Approve / Request-changes
# controls the task page offers. The deep-link target for the blink + push.
class ApprovalsController < ApplicationController
  def index
    items = Task.awaiting_human
                .includes(:project)
                .joins(:project).where(projects: { archived_at: nil })
                .order("projects.name ASC", Arel.sql("tasks.updated_at ASC"))
    @needs_input       = items.select(&:needs_input?).group_by(&:project)
    @awaiting_approval = items.select(&:awaiting_approval?).group_by(&:project)
  end
end
