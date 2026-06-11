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
        AgentSchedule.due.pluck(:id).each do |id|
          AgentSchedule.transaction do
            s = AgentSchedule.lock.find(id)
            next unless s.enabled? && s.next_run_at && s.next_run_at <= Time.current

            launch = s.fire!
            fired << { id: s.id, project: s.project.slug, launch: launch&.id, next_run_at: s.next_run_at } if launch
          end
        end
        render json: { ok: true, fired: fired.size, schedules: fired }
      end
    end
  end
end
