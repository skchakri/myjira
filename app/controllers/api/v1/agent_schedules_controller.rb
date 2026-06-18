module Api
  module V1
    # Host launcher daemon → "fire any schedules that are due now". Each loop the
    # daemon POSTs here; for every due schedule we lock the row, file a
    # SessionLaunch, and advance next_run_at in one transaction, so an overlapping
    # tick can never double-fire. The daemon's pending-poll then spawns the
    # launches. No auth, local-only, like the rest of the API.
    class AgentSchedulesController < BaseController
      def tick
        fired = []
        failed = []
        AgentSchedule.due.pluck(:id).each do |id|
          result = fire_one(id)
          fired  << result[:info] if result[:status] == :fired
          failed << result[:info] if result[:status] == :failed
        end
        render json: { ok: true, fired: fired.size, failed: failed.size, schedules: fired, failures: failed }
      end

      private

      # Fire one due schedule in its own locked transaction. A failure here is
      # caught and recorded against the schedule (next_run_at rolled forward) so a
      # single broken schedule can never abort the tick or block its siblings.
      def fire_one(id)
        outcome = { status: :skipped }
        AgentSchedule.transaction do
          s = AgentSchedule.lock.find(id)
          if s.enabled? && s.next_run_at && s.next_run_at <= Time.current
            launch = s.fire!
            outcome = { status: :fired,
                        info: { id: s.id, project: s.project.slug, launch: launch&.id, next_run_at: s.next_run_at } } if launch
          end
        end
        outcome
      rescue StandardError => e
        record_failure(id, e)
        { status: :failed, info: { id: id, error: e.message } }
      end

      def record_failure(id, error)
        AgentSchedule.find_by(id: id)&.note_failure!(error.message)
        Rails.logger.error("[agent_schedules#tick] #{id} failed: #{error.class} #{error.message}")
      rescue StandardError => e
        Rails.logger.error("[agent_schedules#tick] could not record failure for #{id}: #{e.class} #{e.message}")
      end
    end
  end
end
