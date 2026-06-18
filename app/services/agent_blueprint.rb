# Turns a plain-English request (or "analyse this repo") into the meta-prompt for
# an ordinary SessionLaunch. The spawned `claude` session does the authoring/
# analysis and writes `.claude/agents/*.md` files; the host daemon re-discovers
# them into the project's strip on its next sync. No new Claude integration —
# this just rides the launch pipeline that agent triggers already use.
module AgentBlueprint
  module_function

  # The shape every authored agent file must follow. Kept in one place so the
  # "new" and "suggest" prompts stay consistent with what the daemon parses and
  # what Agent.classify expects in `category`.
  FRONTMATTER_SPEC = <<~SPEC.strip
    YAML frontmatter delimited by `---`, with:
      name: <kebab-case; must match the filename without .md>
      description: <one or two sentences saying when this subagent should be used>
      category: <one of: testing, review, docs, refactor, data, frontend, devops, research, general>
      tools: <optional inline array of the MINIMAL Claude Code tools it needs, e.g. [Read, Grep, Glob, Bash]; omit to inherit all>
      model: <optional: haiku, sonnet, or opus — pick the cheapest that can do the job; omit for the default>
    Then a blank line, then the system prompt itself: focused second-person
    instructions ("You are…", "When invoked you…") covering the subagent's single
    responsibility, its step-by-step process, and what a good result looks like.
  SPEC

  # One named agent from a user's description.
  def new_agent_prompt(name:, description:, category: nil)
    cat_line = category.present? ? "\nPut it in the \"#{category}\" category.\n" : ""
    <<~PROMPT
      Create a new Claude Code subagent in THIS repository.

      Write the file `.claude/agents/#{name}.md` containing:
      #{FRONTMATTER_SPEC}

      The subagent's job, in the user's words:
      #{description}
      #{cat_line}
      Steps:
      1. Briefly inspect the repo (README, CLAUDE.md, the project layout and stack)
         so the system prompt and tool choices fit THIS codebase's conventions.
      2. Read what's already in `.claude/agents/`; don't duplicate an existing one —
         if a close match exists, make yours distinct or refine the brief.
      3. Choose the MINIMAL set of tools and the cheapest capable model.
      4. Write `.claude/agents/#{name}.md` (create the directory if missing).
      5. Print a one-line confirmation: path, category, model, and tools.

      This is a one-shot authoring task — do not modify any other files.
    PROMPT
  end

  # Analyse the repo + how Claude has actually been used here, then propose and
  # write several tailored agents. `digest` comes from activity_digest below.
  def suggest_prompt(project:, digest:)
    <<~PROMPT
      Analyse THIS project — #{project.name} — and propose a small set of
      high-leverage Claude Code subagents tailored to how it's actually worked on,
      then create them.

      ## How Claude has recently been used in this project
      #{digest}

      ## Your task
      1. Explore the repo: stack, frameworks, test setup, build/lint/deploy, and
         the recurring kinds of work the activity above points to (tests, reviews,
         migrations, UI, docs, ops, debugging…).
      2. List what's already in `.claude/agents/` so you propose GAPS, not dupes.
      3. Design 3–6 subagents that would genuinely speed up the recurring work
         here. Each gets one clear responsibility, the MINIMAL tools, and the
         cheapest capable model (haiku/sonnet/opus).
      4. Write each to `.claude/agents/<kebab-name>.md` using:
      #{FRONTMATTER_SPEC}
         Tag each with the best-fitting `category`.
      5. Finish with a short markdown table: name · category · model · one-line
         reason it earns its place for THIS project specifically.

      Create the `.claude/agents/` directory if needed. Don't touch other files.
    PROMPT
  end

  # A compact, plain-text digest of how Claude has been used in this project:
  # recent session subjects + aggregated tool activity (edits, tests, commits,
  # commands, subagents, lookups), read off the rollups Conversation already
  # computes. Fed into suggest_prompt so proposals fit real usage, not guesses.
  def activity_digest(project, limit: 40)
    convos = project.conversations.recent.limit(limit).to_a
    return "No captured Claude sessions yet — base proposals on the codebase itself." if convos.empty?

    subjects = convos.filter_map do |c|
      (c.name.presence || c.title.presence || c.last_context.presence)&.to_s&.strip&.presence
    end.uniq.first(15)

    kinds = Hash.new(0)
    convos.each do |c|
      Array(c.highlights).each do |h|
        k = h.is_a?(Hash) ? h["kind"] : nil
        kinds[k] += 1 if k.present?
      end
    end
    labels = { "edit" => "file edits", "commit" => "commits", "test" => "test runs",
               "run" => "shell commands", "task" => "subagent calls", "web" => "web lookups" }
    activity = kinds.sort_by { |_, n| -n }.map { |k, n| "#{labels[k] || k} ×#{n}" }.join(", ")

    out = ["#{convos.size} recent session(s)."]
    out << "Recurring activity — #{activity}." if activity.present?
    if subjects.any?
      out << "Recent session subjects:"
      subjects.each { |s| out << "  • #{s.truncate(110)}" }
    end
    out.join("\n")
  end
end
