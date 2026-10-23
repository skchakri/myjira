require "test_helper"

class CalendarJobTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Cal", slug: "cal-#{SecureRandom.hex(3)}", repo_path: "/tmp/cal")
  end

  test "sync! upserts the full set for a source and drops what's no longer reported" do
    CalendarJob.sync!("system_cron", [
      { "external_id" => "a", "title" => "Organizer", "cron" => "0 7 * * * America/Denver", "meta" => { "tz" => "America/Denver" } },
      { "external_id" => "b", "title" => "Scan", "cron" => "0 9 1 * *" }
    ])
    assert_equal 2, CalendarJob.where(source: "system_cron").count

    CalendarJob.sync!("system_cron", [{ "external_id" => "a", "title" => "Organizer v2", "cron" => "0 8 * * *" }])
    assert_equal ["Organizer v2"], CalendarJob.where(source: "system_cron").pluck(:title)
  end

  test "sync! keeps a job with an unparseable cron but blanks the expression" do
    CalendarJob.sync!("system_cron", [{ "external_id" => "x", "title" => "Weird", "cron" => "not a cron" }])
    assert_nil CalendarJob.find_by(external_id: "x").cron
  end

  test "sync! never prunes another source or suggestions" do
    suggestion = CalendarJob.create!(source: "suggested", external_id: "s", title: "Deploy", cron: "0 9 * * 1")
    CalendarJob.sync!("systemd_timer", [])
    assert CalendarJob.exists?(suggestion.id)
  end

  test "display_zone comes from the synced host tz" do
    CalendarJob.sync!("system_cron", [{ "external_id" => "a", "title" => "t", "cron" => "0 7 * * *", "meta" => { "tz" => "America/Denver" } }])
    assert_equal "America/Denver", CalendarJob.display_zone.tzinfo.name
  end

  test "promote! creates a paused AgentSchedule once" do
    job = CalendarJob.create!(source: "suggested", external_id: "p", title: "Deploy", command: "deploy it",
                              cron: "0 9 * * 1 America/Denver", project: @project)
    sched = job.promote!
    refute sched.enabled?
    assert_equal "deploy it", sched.prompt
    assert_equal sched, job.reload.agent_schedule
    assert_no_difference -> { AgentSchedule.count } do
      job.promote!
    end
  end

  test "promote! needs a project" do
    job = CalendarJob.create!(source: "suggested", external_id: "q", title: "Invoice", cron: "0 9 1 * *")
    assert_raises(ArgumentError) { job.promote! }
  end
end
