module Api
  module V1
    # Calendar feed in from outside the container.
    #
    #   POST /api/v1/calendar_jobs/sync
    #     { source: "system_cron"|"systemd_timer"|"claude_cron"|"claude_routine",
    #       jobs: [ { external_id:, title:, command:, cron:, schedule_label:,
    #                 next_run_at:, last_run_at:, enabled:, project:, meta: {} } ] }
    #   Full set per source — jobs no longer reported are removed.
    #
    #   POST /api/v1/calendar_jobs/suggestions
    #     { jobs: [ { external_id:, title:, command:, cron:, project:, evidence: } ] }
    #   Upserts repetitive-task suggestions; never prunes, never touches a
    #   suggestion's dismissal or promotion.
    class CalendarJobsController < BaseController
      def sync
        source = params[:source].to_s
        unless CalendarJob::SYNCED_SOURCES.include?(source)
          return render json: { error: "invalid", message: "unknown source #{source.inspect}" }, status: :unprocessable_entity
        end
        kept = CalendarJob.sync!(source, entries)
        render json: { ok: true, source: source, synced: kept }
      end

      def suggestions
        ids = entries.map do |e|
          job = CalendarJob.find_or_initialize_by(source: "suggested", external_id: e["external_id"].to_s)
          job.update!(title: e["title"], command: e["command"], cron: e["cron"], evidence: e["evidence"],
                      schedule_label: e["schedule_label"],
                      project: (Project.find_by(slug: e["project"]) if e["project"].present?) || job.project)
          job.id
        end
        render json: { ok: true, upserted: ids.size }
      end

      private

      def entries
        Array(params[:jobs]).map { |raw| raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h }
      end
    end
  end
end
