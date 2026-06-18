module Api
  module V1
    # Host-side agent discovery → myjira. The launcher daemon walks each repo's
    # .claude/{agents,skills,commands} (and the global ~/.claude ones), parses the
    # frontmatter, and POSTs the catalogue here. Mirrors how repo_path / branches
    # get in: myjira is containerised and can't read the host filesystem itself.
    #
    #   POST /api/v1/agents/sync
    #     { project: "<slug>"|null, scope: "project"|"global",
    #       agents: [ { kind:, name:, description:, category:, model:, tools:, source_path: } ] }
    #
    # `category` is optional — when absent we infer one with Agent.classify.
    #
    # Idempotent full-set upsert per (project, scope): entries present are
    # created/updated; entries in that bucket the daemon no longer reports are
    # disabled, so deleted agent files drop out of the UI. No auth, local-only.
    class AgentsController < BaseController
      def sync
        project = Project.where(slug: params[:project]).first if params[:project].present?
        scope   = params[:scope].presence || (project ? "project" : "global")

        seen = []
        Array(params[:agents]).each do |raw|
          a    = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
          kind = a["kind"].to_s
          name = a["name"].to_s
          next if name.blank? || !Agent::KINDS.include?(kind)

          agent = Agent.find_or_initialize_by(project_id: project&.id, kind: kind, name: name)
          agent.assign_attributes(
            scope: scope,
            description: a["description"],
            category: a["category"].presence || Agent.classify(name, a["description"], a["tools"]),
            model: a["model"].presence,
            tools: Array(a["tools"]),
            source_path: a["source_path"],
            enabled: true,
            discovered_at: Time.current
          )
          agent.save!
          seen << agent.id
        end

        # Anything in this (project, scope) bucket we didn't just see is gone.
        Agent.where(project_id: project&.id, scope: scope)
             .where.not(id: seen)
             .update_all(enabled: false, updated_at: Time.current)

        render json: { ok: true, project: project&.slug, scope: scope, synced: seen.size }
      end
    end
  end
end
