require "test_helper"

# Regression guard: Claude Code removed the TeamCreate/TeamDelete tools in
# v2.1.178 (the implicit-team model replaced them). myjira's launched agents run
# against the host CLI, so any skill/prompt/config that still names a removed
# tool would silently no-op. This test scans the source the daemon ships and
# fails CI permanently if a removed tool name reappears.
#
# Scope is deliberately narrow (app/ lib/ config/ .claude/) — analysis prose in
# tmp/ (e.g. self-improve trend notes) legitimately discusses the removal and
# must not trip the guard. The denylist lives in one place with its changelog
# citation; this test file itself is outside the scanned dirs.
class RemovedCcToolsTest < ActiveSupport::TestCase
  # Tool names removed from Claude Code that must never reappear in shipped src.
  # Cite the changelog version when adding to this list.
  REMOVED_TOOLS = %w[TeamCreate TeamDelete].freeze # removed in CC v2.1.178

  SCAN_DIRS  = %w[app lib config .claude].freeze
  SCAN_GLOBS = %w[*.rb *.erb *.md *.markdown *.yml *.yaml *.json *.txt].freeze

  test "no removed Claude Code tools are referenced in shipped source" do
    pattern  = /#{REMOVED_TOOLS.map { |t| Regexp.escape(t) }.join("|")}/
    offenders = []

    SCAN_DIRS.each do |dir|
      root = Rails.root.join(dir)
      next unless root.directory?

      SCAN_GLOBS.each do |glob|
        Dir.glob(root.join("**", glob)).each do |path|
          File.foreach(path).with_index(1) do |line, lineno|
            offenders << "#{path}:#{lineno}: #{line.strip}" if line.match?(pattern)
          end
        end
      end
    end

    assert_empty offenders,
                 "Removed Claude Code tool(s) #{REMOVED_TOOLS.join('/')} referenced in:\n" +
                 offenders.join("\n")
  end
end
