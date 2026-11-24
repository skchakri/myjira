# Release view of the Work Queue: per GitHub repo, what is merged and not live
# yet, and one Deploy for all of it (WorkQueue::Releases). Reads cached status
# only; the single gh call is the deploy dispatch after the in-page confirm.
class WorkQueueReleasesController < ApplicationController
  before_action :set_slug

  def index
    @releases = WorkQueue::Releases.new(slug: @slug)
    @projects = WorkQueue::Store.new.projects.keys
  end

  def deploy
    repo = params[:repo].to_s
    return redirect_to(work_queue_releases_path(slug: @slug), alert: "Pick a repo to deploy") unless repo.match?(%r{\A[\w.-]+/[\w.-]+\z})

    # Across every project: a deploy ships all of main, whichever queue the tasks sit in.
    ok, message = WorkQueue::Releases.new.deploy(repo)
    redirect_to work_queue_releases_path(slug: @slug), (ok ? :notice : :alert) => message
  end

  private

  def set_slug
    @slug = params[:slug].presence if params[:slug].to_s.match?(/\A[A-Za-z0-9-]+\z/)
  end
end
