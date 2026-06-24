# Runs the auto-test leg for a finished board item: the latest test plan headless
# via Playwright, plus a relay ticket Claude-in-Chrome works for the auth'd/visual
# checks the headless runner can't reach. Returns the TestRun, or nil when the
# item has no test plan yet (an agent generates one when it finishes coding).
module Board
  module TestLeg
    module_function

    def run!(task, initiated_by: "system", environment: nil)
      plan = task.latest_test_plan
      return nil unless plan
      env = environment || task.project.default_environment
      run = plan.test_runs.create!(environment: env, initiated_by: initiated_by)
      PlaywrightRunnerJob.perform_later(run.id, Board::Pipeline.base_url)
      file_relay_leg(task, run)
      run
    rescue StandardError => e
      Rails.logger.error("[board] test leg failed for task #{task.id}: #{e.message}")
      nil
    end

    # File the visual/auth'd leg as a relay ticket in the shared "general" project.
    def file_relay_leg(task, run)
      env  = run.environment
      base = env&.base_url.presence || task.project.default_base_url.presence
      return if base.blank?
      channel = Project.find_by(slug: "general") || task.project
      channel.browser_tasks.create!(
        title: "Visual test: #{task.title}".truncate(80),
        instructions: "Visually verify “#{task.title}” at #{base}. Test plan: #{run.test_plan.title}. " \
                      "Exercise the logged-in / visual flows the headless runner can't, then report pass/fail " \
                      "with a screenshot. myjira run: #{Board::Pipeline.base_url}/test_runs/#{run.id}",
        target_url: base,
        priority: "normal",
        initiated_by: "board",
        source: "board"
      )
    rescue StandardError => e
      Rails.logger.warn("[board] relay leg skipped for task #{task.id}: #{e.message}")
    end
  end
end
