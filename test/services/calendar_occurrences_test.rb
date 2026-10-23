require "test_helper"

class CalendarOccurrencesTest < ActiveSupport::TestCase
  setup do
    @zone = ActiveSupport::TimeZone["America/Denver"]
    @from = @zone.local(2026, 11, 2)
    @to   = @zone.local(2026, 11, 8).end_of_day
  end

  def occurrences
    CalendarOccurrences.new(from: @from, to: @to, zone: @zone).all
  end

  test "expands a daily cron to one occurrence per day in the host zone" do
    CalendarJob.create!(source: "system_cron", external_id: "d", title: "Daily", cron: "0 7 * * * America/Denver")
    occ = occurrences.select { |o| o.title == "Daily" }
    assert_equal 7, occ.size
    assert(occ.all? { |o| o.at.hour == 7 && o.per_day.nil? })
  end

  test "collapses a sub-daily cron to one chip per day with a count" do
    CalendarJob.create!(source: "system_cron", external_id: "f", title: "Every10", cron: "*/10 * * * * America/Denver")
    occ = occurrences.select { |o| o.title == "Every10" }
    assert_equal 7, occ.size
    assert_equal 144, occ.first.per_day
  end

  test "uses next/last instants for jobs without a cron" do
    CalendarJob.create!(source: "systemd_timer", external_id: "t", title: "Timer",
                        next_run_at: @zone.local(2026, 11, 4, 3), last_run_at: @zone.local(2026, 10, 1))
    occ = occurrences.select { |o| o.title == "Timer" }
    assert_equal [4], occ.map { |o| o.at.day }
  end

  test "includes myjira AgentSchedules and skips dismissed jobs" do
    project = Project.create!(name: "Occ", slug: "occ-#{SecureRandom.hex(3)}", repo_path: "/tmp/occ")
    project.agent_schedules.create!(prompt: "weekly thing", cron: "0 15 * * 1")
    CalendarJob.create!(source: "suggested", external_id: "gone", title: "Gone", cron: "0 9 * * *", dismissed_at: Time.current)
    sources = occurrences.map(&:source)
    assert_includes sources, "myjira_schedule"
    refute(occurrences.any? { |o| o.title == "Gone" })
  end
end
