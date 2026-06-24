module Api
  module V1
    # Host launcher daemon → "advance every autopilot project by one step". Called
    # each loop alongside the schedule tick; the orchestrator owns the guardrails
    # (one-at-a-time, daily cap, pause, global stop). #status is a read-only
    # snapshot for the board header / debugging. No auth, local-only.
    class AutopilotController < BaseController
      def tick
        render json: Autopilot::Orchestrator.tick!
      end

      def status
        render json: Autopilot::Orchestrator.status
      end
    end
  end
end
