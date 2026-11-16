require "fugit"

# One recurring job shown on the Calendar. Rows come from three places:
#   * the host daemon's calendar sync — system crontabs, systemd timers and
#     durable Claude Code crons (.claude/scheduled_tasks.json), which myjira
#     can't read itself because it runs in a container;
#   * Claude cloud routines, pushed by a CLI session (it holds the OAuth token);
#   * "suggested" — repetitive asks mined from captured Claude sessions, which
#     the user can promote into a (paused) AgentSchedule.
# myjira's own AgentSchedules are not copied here; CalendarOccurrences reads
# them live. Synced sources are full-set per source: rows the daemon stops
# reporting are deleted. Suggestions are never pruned by a sync.
class CalendarJob < ApplicationRecord
  SOURCES = {
    "myjira_schedule" => { label: "myjira schedule", glyph: "M" },
    "claude_cron"     => { label: "Claude cron",     glyph: "C" },
    "claude_routine"  => { label: "Claude routine",  glyph: "R" },
    "system_cron"     => { label: "System cron",     glyph: "S" },
    "systemd_timer"   => { label: "systemd timer",   glyph: "T" },
    "suggested"       => { label: "Suggested task",  glyph: "?" }
  }.freeze
  SYNCED_SOURCES = %w[system_cron systemd_timer claude_cron claude_routine].freeze

  belongs_to :project, optional: true
  belongs_to :agent_schedule, optional: true

  validates :source, inclusion: { in: SOURCES.keys - ["myjira_schedule"] }
  validates :external_id, presence: true, uniqueness: { scope: :source }
  validates :title, presence: true
  validate  :cron_must_parse

  scope :visible,   -> { where(dismissed_at: nil) }
  scope :suggested, -> { where(source: "suggested") }

  # Zone the host reports its crons in (the daemon sends it); falls back to UTC.
  def self.display_zone
    tz = where(source: SYNCED_SOURCES).where("meta ? 'tz'").order(synced_at: :desc).pick(Arel.sql("meta->>'tz'"))
    ActiveSupport::TimeZone[tz.to_s] || ActiveSupport::TimeZone["UTC"]
  end

  # Full-set upsert for one synced source. Returns the number of rows kept.
  def self.sync!(source, entries, now: Time.current)
    raise ArgumentError, "unsyncable source #{source}" unless SYNCED_SOURCES.include?(source)
    seen = entries.filter_map do |e|
      next if e["external_id"].blank? || e["title"].blank?
      job = find_or_initialize_by(source: source, external_id: e["external_id"].to_s)
      job.assign_attributes(
        title: e["title"].to_s.truncate(200),
        command: e["command"],
        cron: e["cron"].presence,
        schedule_label: e["schedule_label"].presence,
        next_run_at: parse_time(e["next_run_at"]),
        last_run_at: parse_time(e["last_run_at"]),
        enabled: e.key?("enabled") ? ActiveModel::Type::Boolean.new.cast(e["enabled"]) : true,
        project: (Project.find_by(slug: e["project"]) if e["project"].present?),
        meta: e["meta"].is_a?(Hash) ? e["meta"] : {},
        synced_at: now
      )
      job.cron = nil unless job.fugit # never let one bad expression fail the batch
      job.save!
      job.id
    end
    where(source: source).where.not(id: seen).delete_all
    seen.size
  end

  def self.parse_time(v)
    return if v.blank?
    v.is_a?(Numeric) ? Time.zone.at(v) : Time.zone.parse(v.to_s)
  rescue ArgumentError
    nil
  end

  def fugit
    return @fugit if defined?(@fugit)
    @fugit = (Fugit.parse_cron(cron) if cron.present?)
  end

  def source_label = SOURCES.dig(source, :label)
  def suggested?   = source == "suggested"
  def promoted?    = agent_schedule_id.present?

  # Turn a suggestion into a real myjira schedule — created PAUSED, so nothing
  # runs until the user flips it on from the project's schedule strip.
  def promote!
    raise ArgumentError, "only suggestions can be promoted" unless suggested?
    return agent_schedule if promoted?
    raise ArgumentError, "pick a project first" unless project
    transaction do
      sched = project.agent_schedules.create!(prompt: command.presence || title, cron: cron, enabled: false)
      update!(agent_schedule: sched)
      sched
    end
  end

  private

  def cron_must_parse
    errors.add(:cron, "is not a valid cron expression") if cron.present? && fugit.nil?
  end
end
