require "test_helper"

# Focused on the Playbook hook in #fire!: a playbook-driven schedule records a
# PlaybookRun alongside the launch it queues; a plain schedule does not.
class AgentScheduleTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "AS", slug: "as-#{SecureRandom.hex(3)}", repo_path: "/tmp/as")
  end

  test "fire! on a playbook schedule records a PlaybookRun linked to the launch" do
    pb = @project.playbooks.create!(name: "x", body: "y")
    sched = @project.agent_schedules.create!(playbook: pb, prompt: pb.run_prompt, cron: "0 9 * * *")
    assert_difference -> { PlaybookRun.count } => 1, -> { SessionLaunch.count } => 1 do
      launch = sched.fire!
      run = PlaybookRun.last
      assert_equal pb, run.playbook
      assert_equal launch, run.session_launch
      assert_equal sched.id, run.agent_schedule_id
      assert_equal "pending", run.result
    end
  end

  test "fire! on a plain schedule creates no PlaybookRun" do
    sched = @project.agent_schedules.create!(prompt: "just a prompt", cron: "0 9 * * *")
    assert_no_difference -> { PlaybookRun.count } do
      assert_difference -> { SessionLaunch.count }, 1 do
        sched.fire!
      end
    end
  end
end
