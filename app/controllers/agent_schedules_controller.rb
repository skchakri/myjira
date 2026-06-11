# Web side of agent scheduling: create a recurring trigger (from the agent form
# or a free-form prompt), toggle it on/off, run it once on demand, or remove it.
# The actual firing is done by the daemon's tick (Api::V1::AgentSchedulesController).
class AgentSchedulesController < ApplicationController
  def create
    project = find_project!
    agent   = Agent.find_by(id: params[:agent_id])
    prompt  = agent ? agent.launch_prompt(params[:task]) : params[:prompt].to_s.strip

    schedule = project.agent_schedules.new(
      agent: agent,
      task: params[:task].presence,
      prompt: prompt,
      model: params[:model].presence || agent&.launch_model || "default",
      permission_mode: params[:permission_mode].presence || "default",
      cron: params[:cron].to_s.strip
    )

    if schedule.save
      redirect_back fallback_location: project_conversations_path(project),
        notice: "Scheduled #{agent&.name || 'prompt'} · #{schedule.cron} — next run #{format_time(schedule.next_run_at)}."
    else
      redirect_back fallback_location: project_conversations_path(project),
        alert: "Couldn't schedule: #{schedule.errors.full_messages.to_sentence}"
    end
  end

  # Enable / disable without deleting (the strip's switch).
  def toggle
    schedule = AgentSchedule.find(params[:id])
    schedule.update(enabled: !schedule.enabled)
    redirect_back fallback_location: project_conversations_path(schedule.project),
      notice: "Schedule #{schedule.enabled? ? 'enabled' : 'paused'}."
  end

  # Fire immediately, regardless of cron (and still roll next_run_at forward).
  def run_now
    schedule = AgentSchedule.find(params[:id])
    launch = schedule.fire!
    msg = launch ? "Running #{schedule.agent&.name || 'schedule'} now — it'll appear below." :
                   "Couldn't run: no repo path for #{schedule.project.name}."
    redirect_back fallback_location: project_conversations_path(schedule.project), notice: msg
  end

  def destroy
    schedule = AgentSchedule.find(params[:id])
    project  = schedule.project
    schedule.destroy
    redirect_back fallback_location: project_conversations_path(project), notice: "Schedule removed."
  end

  private

  def find_project!
    Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
  end
end
