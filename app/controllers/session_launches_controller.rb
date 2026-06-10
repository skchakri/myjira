# Web side of "launch a new Claude session from the Conversations page". Creating
# a launch pre-creates the placeholder Conversation (so it shows in the grid at
# once) and queues the request; the host-side daemon does the actual `claude`
# spawn in a tmux window. See SessionLaunch and myjira_session_launcher.py.
class SessionLaunchesController < ApplicationController
  def create
    project = find_project!
    prompt  = params[:prompt].to_s.strip

    if prompt.blank?
      return redirect_back fallback_location: project_conversations_path(project),
        alert: "Type a prompt to launch a session with."
    end
    if project.repo_path.blank?
      return redirect_back fallback_location: project_conversations_path(project),
        alert: "No repo path known for #{project.name} yet — run Claude in that folder once so myjira learns where it is."
    end

    ActiveRecord::Base.transaction do
      launch = project.session_launches.create!(
        prompt: prompt,
        model: params[:model].presence || "default",
        permission_mode: params[:permission_mode].presence || "default"
      )
      convo = project.conversations.create!(
        session_id: launch.session_id,
        source: "launched",
        title: prompt.split("\n").map(&:strip).find(&:present?).to_s.truncate(80),
        cwd: project.repo_path,
        started_at: Time.current,
        last_message_at: Time.current
      )
      launch.update!(conversation: convo)
    end

    redirect_back fallback_location: project_conversations_path(project),
      notice: "Launching a Claude session in #{project.name} — it'll open in a tmux window and appear below."
  rescue ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: conversations_path, alert: "Couldn't launch: #{e.record.errors.full_messages.to_sentence}"
  end

  # Pull a queued/launching request before the daemon gets to it (or stop showing
  # a stuck one). Doesn't kill a tmux window that's already up.
  def cancel
    launch = SessionLaunch.find(params[:id])
    launch.update(status: "canceled") unless launch.done?
    redirect_back fallback_location: conversations_path, notice: "Launch canceled."
  end

  # Auto-reloading strip on the Conversations index (mirrors the "Live now"
  # frame): shows in-flight launches + the attach command for each.
  def active
    @launches = SessionLaunch.active.recent.includes(:project, :conversation).limit(12)
    render layout: false
  end

  private

  def find_project!
    Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
  end
end
