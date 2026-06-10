# Web → "run this agent here". Turns a discovered Agent into a SessionLaunch:
# we build the prompt (Agent#launch_prompt) and queue a launch in the project's
# repo. From there it's the exact same pipeline as the "+ New session" button —
# the host daemon spawns `claude --session-id` and the live conversation folds in.
class AgentTriggersController < ApplicationController
  def trigger
    project = find_project!
    agent   = Agent.find(params[:id])

    if project.repo_path.blank?
      return redirect_back fallback_location: project_conversations_path(project),
        alert: "No repo path known for #{project.name} yet — run Claude in that folder once so myjira learns where it is."
    end

    prompt = agent.launch_prompt(params[:task])
    model  = params[:model].presence || agent.launch_model || "default"
    perms  = params[:permission_mode].presence || "default"

    ActiveRecord::Base.transaction do
      launch = project.session_launches.create!(
        prompt: prompt, model: model, permission_mode: perms, agent: agent
      )
      convo = project.conversations.create!(
        session_id: launch.session_id,
        source: "launched",
        title: "#{agent.glyph} #{agent.name} · #{prompt}".truncate(80),
        cwd: project.repo_path,
        started_at: Time.current,
        last_message_at: Time.current
      )
      launch.update!(conversation: convo)
    end

    redirect_back fallback_location: project_conversations_path(project),
      notice: "Triggering #{agent.name} in #{project.name} — it'll open in a tmux window and appear below."
  rescue ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: conversations_path,
      alert: "Couldn't trigger #{agent&.name}: #{e.record.errors.full_messages.to_sentence}"
  end

  private

  def find_project!
    Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
  end
end
