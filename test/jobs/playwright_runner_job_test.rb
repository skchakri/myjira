require "test_helper"

class PlaywrightRunnerJobTest < ActiveSupport::TestCase
  test "command builds a shell-free argv from valid input" do
    id = SecureRandom.uuid
    assert_equal [ "node", "index.js", "--run-id=#{id}", "--myjira=http://localhost:1200", "--headless" ],
                 PlaywrightRunnerJob.command(id, "http://localhost:1200")
  end

  test "command rejects odd run ids and urls" do
    assert_raises(ArgumentError) { PlaywrightRunnerJob.command("1; rm -rf /", "http://localhost:1200") }
    assert_raises(ArgumentError) { PlaywrightRunnerJob.command(SecureRandom.uuid, "http://x/$(id)") }
    assert_raises(ArgumentError) { PlaywrightRunnerJob.command(SecureRandom.uuid, "file:///etc/passwd") }
  end
end
