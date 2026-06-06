module Api
  module V1
    # The web → live-session command channel, keyed by CLI session_id.
    #
    #   GET   /api/v1/sessions/:session_id/commands?status=pending&wait=25&since=
    #         — the listener long-polls for new commands to run
    #   PATCH /api/v1/sessions/:session_id/commands/:id   {status,result}
    #         — the listener marks a command running, then done with its result
    class SessionCommandsController < BaseController
      MAX_WAIT = 30

      def index
        convo = Conversation.find_by(session_id: params[:session_id].to_s)
        return render(json: { commands: [], cursor: nil }) unless convo

        wait  = params[:wait].to_i.clamp(0, MAX_WAIT)
        since = parse_time(params[:since])
        scope = -> { command_scope(convo, since) }

        if wait.positive?
          deadline = Time.current + wait
          loop do
            break if scope.call.exists?
            break if Time.current >= deadline
            sleep 1.0
          end
        end

        cmds = scope.call.order(:created_at).to_a
        render json: {
          session_id: params[:session_id], conversation_id: convo.id,
          commands: cmds.map { |c| serialize(c) },
          cursor: (cmds.last&.created_at || since || Time.current).iso8601(6)
        }
      end

      def update
        convo = Conversation.find_by!(session_id: params[:session_id].to_s)
        cmd   = convo.session_commands.find(params[:id])
        attrs = { status: params[:status], result: params[:result] }.compact
        attrs[:responded_at] = Time.current if %w[done failed].include?(attrs[:status])
        cmd.update!(attrs.slice(:status, :result, :responded_at))
        render json: serialize(cmd)
      end

      private

      # Default to fresh, unfinished commands (pending). A listener can also pass
      # status= to scope differently. `since` only returns newer rows.
      def command_scope(convo, since)
        rel = convo.session_commands
        rel = rel.where(status: params[:status].presence || "pending")
        rel = rel.where("created_at > ?", since) if since
        rel
      end

      def serialize(c)
        { id: c.id, body: c.body, status: c.status, result: c.result,
          source: c.source, created_at: c.created_at.iso8601(6),
          responded_at: c.responded_at&.iso8601(6),
          attachments: c.files.map { |f|
            { filename: f.filename.to_s, content_type: f.content_type,
              byte_size: f.byte_size, url: "#{base_url}#{rails_blob_path(f)}" }
          } }
      end

      def parse_time(raw)
        return nil if raw.blank?
        Time.iso8601(raw.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
