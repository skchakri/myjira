require "test_helper"

# WorklogSubscriber turns a tagged Rails.event into a persisted WorklogEvent and
# a Turbo append. We hand-build the event hash the reporter would pass to #emit
# (so the test doesn't depend on the reporter wiring) and stub the broadcast.
class WorklogSubscriberTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "WS", slug: "ws-#{SecureRandom.hex(3)}", repo_path: "/tmp/ws")
    @task = @project.tasks.create!(title: "x", item_type: "task", board_state: "pending")
    @subscriber = WorklogSubscriber.new
  end

  def event(name:, subject:, status: "running", label: "step", payload: {}, tagged: true, timestamp: nil)
    {
      name: name,
      payload: { subject: subject, status: status, label: label, payload: payload },
      tags: tagged ? { worklog: true } : {},
      timestamp: timestamp
    }
  end

  test "emit persists a WorklogEvent from a tagged event" do
    Turbo::StreamsChannel.stub(:broadcast_append_to, nil) do
      assert_difference -> { WorklogEvent.count }, 1 do
        @subscriber.emit(event(name: "launch.spawned", subject: @task, label: "Spawned claude"))
      end
    end
    e = @task.worklog_events.chronological.last
    assert_equal "launch.spawned", e.name
    assert_equal "Spawned claude", e.label
    assert_equal "running", e.status
  end

  test "emit ignores events not tagged worklog" do
    assert_no_difference -> { WorklogEvent.count } do
      @subscriber.emit(event(name: "other.thing", subject: @task, tagged: false))
    end
  end

  test "emit ignores events without a subject" do
    ev = event(name: "x", subject: nil)
    assert_no_difference -> { WorklogEvent.count } do
      @subscriber.emit(ev)
    end
  end

  test "emit converts the nanosecond timestamp to occurred_at" do
    fixed = Time.zone.local(2026, 6, 26, 12, 0, 0)
    nanos = (fixed.to_r * 1_000_000_000).to_i
    Turbo::StreamsChannel.stub(:broadcast_append_to, nil) do
      @subscriber.emit(event(name: "n", subject: @task, timestamp: nanos))
    end
    assert_in_delta fixed.to_f, @task.worklog_events.last.occurred_at.to_f, 0.001
  end

  test "a broadcast failure does not lose the persisted row" do
    boom = ->(*) { raise "cable down" }
    Turbo::StreamsChannel.stub(:broadcast_append_to, boom) do
      assert_difference -> { WorklogEvent.count }, 1 do
        @subscriber.emit(event(name: "n", subject: @task))
      end
    end
  end
end
