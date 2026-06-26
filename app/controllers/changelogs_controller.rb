# Per-project "What's New" — a plain-language feed of shipped changes for normal
# end-users (not a developer changelog). An entry is a done board item that
# carries a `changelog_summary` blurb; optional image/video attachments captured
# during a relay test run render as a visual walkthrough.
class ChangelogsController < ApplicationController
  def show
    @project = Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
    @entries = @project.tasks.with_attached_attachments.changelog
  end
end
