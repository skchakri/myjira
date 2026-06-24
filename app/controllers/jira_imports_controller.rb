# Imports an Atlassian Jira ticket (by pasted URL) into this project's board.
# Delegates the work to Jira::Importer and turns Jira::Error into a friendly
# board flash. Lands the item in the project the request is scoped to.
class JiraImportsController < ApplicationController
  before_action :set_project

  def create
    unless JiraConnection.configured?
      return redirect_to board_path(@project),
        alert: "Connect Jira first — set your site, email and API token in Jira settings."
    end

    result = Jira::Importer.import(url: params[:url], project: @project)
    redirect_to board_path(@project), notice: import_notice(result)
  rescue Jira::Error => e
    redirect_to board_path(@project), alert: e.user_message
  end

  private

  def set_project
    @project = Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
  end

  # A board flash summarising the import: verb + key + title, how many
  # attachments were added, and (so a partial failure isn't hidden) how many
  # couldn't be downloaded.
  def import_notice(result)
    bits = ["#{result.created ? 'Imported' : 'Updated'} #{result.task.external_ref} — “#{result.task.title}”"]
    if result.attachments_added.positive?
      bits << "#{result.attachments_added} attachment#{'s' if result.attachments_added != 1} added"
    end
    if result.attachments_skipped.any?
      n = result.attachments_skipped.size
      bits << "#{n} attachment#{'s' if n != 1} couldn't be downloaded"
    end
    "#{bits.join(' · ')}."
  end
end
