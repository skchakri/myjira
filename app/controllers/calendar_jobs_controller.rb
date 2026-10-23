# Calendar item detail (rendered into the page's drawer frame) and the actions on
# a suggestion: promote it into a paused AgentSchedule, or dismiss / restore it.
class CalendarJobsController < ApplicationController
  def show
    @item = params[:type] == "schedule" ? AgentSchedule.find(params[:id]) : CalendarJob.find(params[:id])
    @zone = CalendarJob.display_zone
    cron = @item.cron.presence && Fugit.parse_cron(@item.cron)
    @next_runs = []
    t = Time.current
    5.times { @next_runs << (t = cron.next_time(t + 1).to_t) } if cron
    @projects = Project.active.order(:name) if @item.is_a?(CalendarJob) && @item.suggested?
  end

  def promote
    job = CalendarJob.find(params[:id])
    job.update!(project: Project.find(params[:project_id])) if params[:project_id].present?
    sched = job.promote!
    redirect_back fallback_location: calendar_path,
      notice: "Added to #{sched.project.name}'s schedules (paused) — turn it on from the project's schedule strip."
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: calendar_path, alert: "Couldn't schedule: #{e.message}"
  end

  def dismiss
    CalendarJob.find(params[:id]).update!(dismissed_at: Time.current)
    redirect_back fallback_location: calendar_path, notice: "Suggestion dismissed."
  end
end
