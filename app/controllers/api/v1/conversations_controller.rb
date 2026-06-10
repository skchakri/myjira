module Api
  module V1
    # Captures Claude CLI conversations across every local project.
    #
    #   POST /api/v1/conversations/sync   — a Stop hook posts new transcript turns
    #   GET  /api/v1/conversations        — list (optionally ?project=slug)
    #   GET  /api/v1/conversations/:id    — one conversation + its messages
    #
    # sync is idempotent: the project is found-or-created from the working dir,
    # the conversation from the CLI sessionId, and each message from its ext_id —
    # so the hook can re-send freely after a failure and nothing duplicates.
    class ConversationsController < BaseController
      def index
        scope = Conversation.all
        if params[:project].present?
          project = Project.where(slug: params[:project]).or(Project.where(id: params[:project])).first!
          scope = project.conversations
        end
        render json: scope.recent.includes(:project).limit((params[:limit] || 100).to_i).map { |c| serialize(c) }
      end

      def show
        convo = Conversation.find(params[:id])
        render json: detailed(convo)
      end

      # Lightweight lookup for the CLI statusline: given a CLI session_id, return
      # the user-set name (and display title). Empty name when none / unknown.
      def name
        convo = Conversation.find_by(session_id: params[:session_id].to_s)
        render json: {
          session_id: params[:session_id].to_s,
          name: convo&.name,
          display_title: convo&.display_title
        }
      end

      def sync
        project = upsert_project!
        convo   = upsert_conversation!(project)
        inserted = append_messages!(convo)
        convo.refresh_counts!

        render json: {
          ok: true,
          conversation_id: convo.id,
          project: project.slug,
          inserted: inserted,
          total_messages: convo.message_count,
          urls: {
            web: "#{base_url}/conversations/#{convo.id}",
            api: "#{base_url}/api/v1/conversations/#{convo.id}"
          }
        }, status: :ok
      end

      private

      def upsert_project!
        pp = params.require(:project)
        slug = pp[:slug].to_s
        project = Project.find_or_create_by!(slug: slug) do |p|
          p.name      = pp[:name].presence || slug
          p.repo_path = pp[:repo_path]
        end
        if pp[:repo_path].present? && project.repo_path != pp[:repo_path]
          project.update_columns(repo_path: pp[:repo_path])
        end
        # Recent branches ride along only on throttled "git refresh" turns; absent
        # key → leave the last-known list untouched (don't wipe it every turn).
        if pp.key?(:branches)
          project.update_columns(branches: jsonify(pp[:branches]).first(20),
                                 branches_synced_at: Time.current)
        end
        project
      end

      def upsert_conversation!(project)
        cp = params.require(:conversation)
        convo = Conversation.find_or_initialize_by(session_id: cp[:session_id].to_s)
        convo.project       = project
        convo.cwd         ||= cp[:cwd]
        convo.git_branch    = cp[:git_branch] if cp[:git_branch].present?
        convo.source        = cp[:source].presence || "claude-cli"
        convo.model         = cp[:model] if cp[:model].present?
        convo.title         = cp[:title] if cp[:title].present?
        # PRs for git_branch ride along on git-refresh turns; an explicit []
        # clears stale PRs (e.g. after a merge), so key-present (not value) gates.
        convo.prs           = jsonify(cp[:prs]).first(6) if cp.key?(:prs)
        convo.started_at  ||= parse_time(cp[:started_at]) || Time.current
        convo.save!
        convo
      end

      def append_messages!(convo)
        next_position = (convo.conversation_messages.maximum(:position) || -1) + 1
        inserted = 0
        Array(params[:messages]).each do |raw|
          m = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
          ext_id = m[:ext_id].presence || m["ext_id"].presence
          next if ext_id.blank?

          msg = convo.conversation_messages.find_or_initialize_by(ext_id: ext_id)
          next if msg.persisted? # already captured

          msg.role        = (m[:role] || m["role"]).presence || "assistant"
          msg.kind        = (m[:kind] || m["kind"]).presence || "message"
          msg.body        = (m[:body] || m["body"]).to_s
          msg.payload     = (m[:payload] || m["payload"]) || {}
          msg.occurred_at = parse_time(m[:occurred_at] || m["occurred_at"]) || Time.current
          msg.position    = next_position
          next if msg.body.blank? && msg.kind != "tool"

          msg.save!
          next_position += 1
          inserted += 1
        end
        inserted
      end

      def parse_time(raw)
        return nil if raw.blank?
        Time.iso8601(raw.to_s)
      rescue ArgumentError
        (Time.at(raw.to_f) rescue nil)
      end

      # Recursively turn permitted/unpermitted params (incl. arrays of objects)
      # into plain JSON-able Ruby for jsonb columns — these payloads are trusted
      # (local-only sync hook), so no per-key permitting.
      def jsonify(val)
        case val
        when ActionController::Parameters then val.to_unsafe_h
        when Array then val.map { |v| jsonify(v) }
        when Hash then val.transform_values { |v| jsonify(v) }
        else val
        end
      end

      def serialize(convo)
        {
          id: convo.id,
          title: convo.display_title,
          project: convo.project.slug,
          session_id: convo.session_id,
          source: convo.source,
          model: convo.model,
          git_branch: convo.git_branch,
          prs: convo.prs,
          last_context: convo.last_context,
          highlights: convo.highlights,
          cwd: convo.cwd,
          message_count: convo.message_count,
          started_at: convo.started_at,
          last_message_at: convo.last_message_at,
          url: "#{base_url}/conversations/#{convo.id}"
        }
      end

      def detailed(convo)
        serialize(convo).merge(
          messages: convo.conversation_messages.map do |m|
            { id: m.id, role: m.role, kind: m.kind, body: m.body, payload: m.payload,
              position: m.position, occurred_at: m.occurred_at&.iso8601(6) }
          end
        )
      end
    end
  end
end
