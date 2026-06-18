# Web → "have Claude author an agent for me." Both actions build a meta-prompt
# (AgentBlueprint) and queue an ordinary SessionLaunch in the project's repo with
# bypassPermissions; the spawned `claude` session writes `.claude/agents/*.md`,
# which the daemon then re-discovers into this folder's strip.
#
#   create  → author one named agent from a plain-English description (Phase 1)
#   suggest → analyse the repo + this project's captured activity and propose
#             several tailored agents (Phase 2)
class AgentBuildsController < ApplicationController
  def create
    project = find_project!
    return missing_repo(project) if project.repo_path.blank?

    name = normalize_name(params[:name])
    desc = params[:description].to_s.strip

    if name.blank? || desc.blank?
      return redirect_back fallback_location: project_conversations_path(project),
        alert: "Give the agent a kebab-case name and a description of what it should do."
    end

    prompt = AgentBlueprint.new_agent_prompt(name: name, description: desc, category: params[:category].presence)
    SessionLaunch.queue!(
      project: project, prompt: prompt,
      model: params[:model].to_s.presence_in(SessionLaunch::MODELS) || "default",
      permission_mode: "bypassPermissions",
      title: "✚ author agent · #{name}"
    )

    redirect_back fallback_location: project_conversations_path(project),
      notice: "Claude is authoring the “#{name}” agent in #{project.name} — it appears in this folder's strip once written."
  rescue ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: project_conversations_path(project),
      alert: "Couldn't start the authoring session: #{e.record.errors.full_messages.to_sentence}"
  end

  def suggest
    project = find_project!
    return missing_repo(project) if project.repo_path.blank?

    digest = AgentBlueprint.activity_digest(project)
    prompt = AgentBlueprint.suggest_prompt(project: project, digest: digest)
    SessionLaunch.queue!(
      project: project, prompt: prompt,
      model: "default", permission_mode: "bypassPermissions",
      title: "✨ suggest agents · #{project.name}"
    )

    redirect_back fallback_location: project_conversations_path(project),
      notice: "Claude is analysing #{project.name} and proposing agents — watch the session below; new agents land in the strip as they're written."
  rescue ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: project_conversations_path(project),
      alert: "Couldn't start the suggestion session: #{e.record.errors.full_messages.to_sentence}"
  end

  private

  def normalize_name(raw)
    raw.to_s.strip.downcase.gsub(/[^a-z0-9\-]+/, "-").gsub(/\A-+|-+\z/, "")
  end

  def missing_repo(project)
    redirect_back fallback_location: project_conversations_path(project),
      alert: "No repo path known for #{project.name} yet — run Claude in that folder once so myjira learns where it is."
  end

  def find_project!
    Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
  end
end
