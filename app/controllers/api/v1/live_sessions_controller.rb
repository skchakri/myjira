module Api
  module V1
    # Every live Claude CLI session, for another app to show (Homey's Sessions page).
    #
    #   GET /api/v1/sessions/live?messages=20&commands=10
    #
    # "Live" is Conversation.live (a turn synced in the last LIVE_WINDOW);
    # "listening" is Conversation#listening? (its myjira-listen listener polled
    # the command inbox recently), i.e. whether a command sent now will run.
    # Message bodies are truncated so the payload stays small.
    class LiveSessionsController < BaseController
      LIMIT = 30
      MAX_MESSAGES = 50
      MAX_COMMANDS = 25
      BODY_LIMIT = 2_000

      def index
        n_messages = params.fetch(:messages, 20).to_i.clamp(0, MAX_MESSAGES)
        n_commands = params.fetch(:commands, 10).to_i.clamp(0, MAX_COMMANDS)
        convos = Conversation.live.recent.includes(:project).limit(LIMIT)

        render json: {
          generated_at: Time.current.iso8601,
          live_window_seconds: Conversation::LIVE_WINDOW.to_i,
          sessions: convos.map { |c| serialize(c, n_messages, n_commands) }
        }
      end

      private

      def serialize(convo, n_messages, n_commands)
        {
          session_id: convo.session_id,
          conversation_id: convo.id,
          name: convo.name,
          title: convo.display_title,
          project: convo.project&.slug,
          project_name: convo.project&.name,
          repo_path: convo.project&.repo_path,
          cwd: convo.cwd,
          git_branch: convo.git_branch,
          model: convo.model,
          source: convo.source,
          message_count: convo.message_count,
          started_at: convo.started_at&.iso8601,
          last_message_at: convo.last_message_at&.iso8601,
          live: convo.live?,
          listening: convo.listening?,
          listener_seen_at: convo.listener_seen_at&.iso8601,
          url: "#{base_url}/conversations/#{convo.id}",
          messages: recent_messages(convo, n_messages),
          commands: recent_commands(convo, n_commands)
        }
      end

      def recent_messages(convo, limit)
        return [] if limit.zero?

        convo.conversation_messages.order(position: :desc).limit(limit).to_a.reverse.map do |m|
          { role: m.role, kind: m.kind, tool: m.tool_name, body: m.body.to_s.truncate(BODY_LIMIT),
            occurred_at: m.occurred_at&.iso8601 }
        end
      end

      def recent_commands(convo, limit)
        return [] if limit.zero?

        convo.session_commands.recent.limit(limit).map do |c|
          { id: c.id, body: c.body.to_s.truncate(BODY_LIMIT), status: c.status, source: c.source,
            result: c.result.to_s.truncate(BODY_LIMIT).presence,
            created_at: c.created_at.iso8601, responded_at: c.responded_at&.iso8601 }
        end
      end
    end
  end
end
