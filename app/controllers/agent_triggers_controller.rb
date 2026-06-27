# Web → "run this agent here". Turns a discovered Agent into a SessionLaunch:
# we build the prompt (Agent#launch_prompt) and queue a launch in the project's
# repo. From there it's the exact same pipeline as the "+ New session" button —
# the host daemon spawns `claude --session-id` and the live conversation folds in.
class AgentTriggersController < ApplicationController
  def trigger
    project = find_project!
    # Agent id usually comes from the path (:id); the "Run an agent on this item"
    # card on a task page posts to a fixed path and picks the agent via :agent_id.
    agent   = Agent.find(params[:agent_id].presence || params[:id])
    # Optional: launch FROM a board item, so its result lands back on the task.
    task    = project.tasks.find(params[:task_id]) if params[:task_id].present?

    if project.repo_path.blank?
      return redirect_back fallback_location: (task ? project_task_path(project, task) : project_conversations_path(project)),
        alert: "No repo path known for #{project.name} yet — run Claude in that folder once so myjira learns where it is."
    end

    # Seed the prompt from the item when no explicit objective was typed.
    objective = params[:task].presence || task&.then { |t| [t.title, t.description].compact.join("\n\n") }
    prompt = agent.launch_prompt(objective)
    model  = params[:model].presence || agent.launch_model || "default"
    perms  = params[:permission_mode].presence || "default"

    SessionLaunch.queue!(
      project: project, prompt: prompt, model: model, permission_mode: perms,
      agent: agent, task: task, title: "#{agent.glyph} #{agent.name} · #{prompt}"
    )

    if task
      redirect_back fallback_location: project_task_path(project, task),
        notice: "Running #{agent.name} on this item — its result will be posted to the comments when it finishes."
    else
      redirect_back fallback_location: project_conversations_path(project),
        notice: "Triggering #{agent.name} in #{project.name} — it'll open in a tmux window and appear below."
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: conversations_path,
      alert: "Couldn't trigger #{agent&.name}: #{e.record.errors.full_messages.to_sentence}"
  end

  # Remove an agent from this folder's strip. Deletes its `.claude` file when the
  # host path is reachable from here (myjira bind-mounts the repos), and always
  # disables the row so it disappears immediately. If the file survives (e.g. the
  # mount is read-only), the next daemon sync would re-enable it — so we say so.
  def destroy
    project = find_project!
    agent   = Agent.find(params[:id])

    if agent.scope == "global"
      return redirect_back fallback_location: project_conversations_path(project),
        alert: "#{agent.name} is a global agent — remove its file under ~/.claude to drop it everywhere."
    end

    removed = delete_source_file(agent)
    agent.update(enabled: false)

    msg = if removed
      "Removed #{agent.name}."
    else
      "Hid #{agent.name} from the strip. Its file couldn't be deleted from here — " \
        "remove #{agent.source_path.presence || 'it'} on the host to drop it for good."
    end
    redirect_back fallback_location: project_conversations_path(project), notice: msg
  end

  private

  def delete_source_file(agent)
    path = agent.source_path.to_s
    return false if path.blank? || !File.file?(path)

    File.delete(path)
    !File.exist?(path)
  rescue SystemCallError
    false
  end

  def find_project!
    Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
  end
end
