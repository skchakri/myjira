module Api
  module V1
    # Receives Claude Code HTTP hook payloads (Stop, SubagentStop, PostToolUse)
    # from daemon-launched board sessions. Looks up the task via session_id,
    # logs activity to the worklog, and can return { decision: "block" } to gate
    # a SubagentStop when the task is in the waiting state.
    #
    # Always returns 200 — a hook failure must never crash a running Claude session.
    class AgentEventsController < BaseController
      rescue_from StandardError, with: :safe_error

      def create
        session_id = params[:session_id].to_s.strip
        event_type = params[:hook_event_type].to_s.strip

        task = task_for_session(session_id)
        result = task ? route_event(task, event_type) : {}

        render json: result
      end

      private

      def task_for_session(session_id)
        return nil if session_id.blank?
        SessionLaunch.find_by(session_id: session_id)&.task
      end

      def route_event(task, event_type)
        case event_type
        when "Stop", "SubagentStop"
          handle_stop(task, event_type)
        when "PostToolUse"
          handle_post_tool_use(task)
          {}
        else
          {}
        end
      end

      def handle_stop(task, event_type)
        usage  = params[:usage] || {}
        tokens = [
          ("in=#{usage[:input_tokens]}"   if usage[:input_tokens].present?),
          ("out=#{usage[:output_tokens]}"  if usage[:output_tokens].present?),
          ("cache_read=#{usage[:cache_read_input_tokens]}" if usage[:cache_read_input_tokens].present?)
        ].compact.join(" ")
        label = "#{event_type} — #{tokens.presence || 'no usage reported'}"
        task.emit_worklog("agent.#{event_type.underscore}", status: "info", label: label,
                          payload: usage.to_unsafe_h.slice("input_tokens", "output_tokens",
                                                           "cache_read_input_tokens", "cache_creation_input_tokens"))

        if event_type == "SubagentStop" && task.board_state == "waiting"
          { decision: "block", additionalContext: task.agent_notes.presence || "Task is waiting for human input." }
        else
          {}
        end
      end

      def handle_post_tool_use(task)
        tool   = params[:tool_name].to_s
        return unless tool == "Bash"
        cmd    = params.dig(:tool_input, :command).to_s.truncate(200)
        return if cmd.blank?
        task.emit_worklog("agent.bash", status: "info", label: "Bash: #{cmd}",
                          payload: { command: cmd })
      end

      def safe_error(e)
        Rails.logger.warn("[agent_events] #{e.class}: #{e.message}")
        render json: {}
      end
    end
  end
end
