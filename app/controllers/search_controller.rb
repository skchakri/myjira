# Global full-text search across everything myjira captures — board items,
# follow-ups, captured CLI conversation turns (incl. tool payloads) and test
# results. One GET /search?q=… , optionally scoped to a project (?project_id=).
# Postgres FTS via the Searchable concern; results are grouped with deep links.
class SearchController < ApplicationController
  # Per-group result cap — keeps one noisy group from swamping the page. The view
  # surfaces a "showing first N" note when a group is truncated.
  PER_GROUP = 25

  def index
    @q = params[:q].to_s.strip
    @project = resolve_project
    @groups = []
    @total = 0
    return if @q.blank?

    @groups = build_groups
    @total = @groups.sum { |g| g[:records].size }
  end

  private

  # Project scope accepts a slug or a uuid (like ConversationsController#index);
  # an unknown value 404s rather than silently searching everything.
  def resolve_project
    return nil if params[:project_id].blank?
    Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
  end

  def build_groups
    [
      { key: :tasks,        label: "Board items",           records: task_results },
      { key: :follow_ups,   label: "Follow-ups",            records: follow_up_results },
      { key: :messages,     label: "Conversation messages", records: message_results },
      { key: :test_results, label: "Test results",          records: test_result_results }
    ]
  end

  def task_results
    scope = Task.full_text(@q).includes(:project)
    scope = scope.where(project_id: @project.id) if @project
    scope.limit(PER_GROUP).to_a
  end

  def follow_up_results
    scope = FollowUpTask.full_text(@q).includes(:project)
    scope = scope.where(project_id: @project.id) if @project
    scope.limit(PER_GROUP).to_a
  end

  def message_results
    scope = ConversationMessage.full_text(@q).includes(conversation: :project)
    scope = scope.joins(:conversation).where(conversations: { project_id: @project.id }) if @project
    scope.limit(PER_GROUP).to_a
  end

  def test_result_results
    scope = TestResult.full_text(@q).includes(:test_case, test_run: { test_plan: :project })
    scope = scope.joins(test_run: :test_plan).where(test_plans: { project_id: @project.id }) if @project
    scope.limit(PER_GROUP).to_a
  end
end
