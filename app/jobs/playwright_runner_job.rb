require "open3"

# Spawns the local Playwright + Claude CLI runner. Streams its stdout into
# the Rails log so failures are debuggable from `tail -f log/development.log`.
# Uses headless mode by default — visible mode requires a display server the
# Rails process likely cannot reach.
class PlaywrightRunnerJob < ApplicationJob
  queue_as :default

  RUN_ID_FORMAT = /\A[0-9a-f-]{1,64}\z/i
  BASE_URL_FORMAT = %r{\Ahttps?://[^\s"'`$;|&<>]+\z}

  def perform(run_id, myjira_base_url)
    script_dir = Rails.root.join("script/playwright_runner")
    cmd = self.class.command(run_id, myjira_base_url)

    Rails.logger.info("[playwright_runner] spawn #{cmd.join(' ')} (cwd=#{script_dir})")

    Open3.popen2e({ "NO_COLOR" => "1" }, *cmd, chdir: script_dir.to_s) do |stdin, stdout_err, wait_thr|
      stdin.close
      stdout_err.each_line { |line| Rails.logger.info("[playwright_runner] #{line.chomp}") }
      status = wait_thr.value
      Rails.logger.info("[playwright_runner] exit #{status.exitstatus}")
    end
  rescue Errno::ENOENT => e
    Rails.logger.error("[playwright_runner] node binary not found: #{e.message}")
    TestRun.find(run_id).update!(summary: "Playwright runner failed: node not in PATH")
  rescue => e
    Rails.logger.error("[playwright_runner] #{e.class}: #{e.message}")
    raise
  end

  # argv for the runner. Spawned without a shell (array form), and both values
  # are validated first so nothing odd ever reaches node's argument parser.
  def self.command(run_id, myjira_base_url)
    run_id = run_id.to_s
    myjira_base_url = myjira_base_url.to_s
    raise ArgumentError, "invalid run id: #{run_id.inspect}" unless run_id.match?(RUN_ID_FORMAT)
    raise ArgumentError, "invalid myjira url: #{myjira_base_url.inspect}" unless myjira_base_url.match?(BASE_URL_FORMAT)

    [ "node", "index.js", "--run-id=#{run_id}", "--myjira=#{myjira_base_url}", "--headless" ]
  end
end
