require "test_helper"

module WorkQueue
  class ProjectEnvTest < ActiveSupport::TestCase
    setup { @dir = Dir.mktmpdir }
    teardown { FileUtils.rm_rf(@dir) }

    def touch(rel, body = "")
      FileUtils.mkdir_p(File.dirname(File.join(@dir, rel)))
      File.write(File.join(@dir, rel), body)
    end

    test "unsets the runner's Bundler, Ruby and Rails env and leads PATH with the project's Ruby" do
      touch(".ruby-version", "3.3.13\n")
      wrapper = File.join(ProjectEnv::RVM, "wrappers", "ruby-3.3.13")
      runner = { "BUNDLE_GEMFILE" => "/x/myjira/Gemfile", "BUNDLER_ORIG_PATH" => "p", "RUBYOPT" => "-rbundler/setup",
                 "RUBYLIB" => "/l", "GEM_HOME" => "/g", "RAILS_ENV" => "development", "DATABASE_HOST" => "127.0.0.1",
                 "REDIS_URL" => "redis://x/12", "HOME" => "/home/u",
                 "PATH" => "#{ProjectEnv::RVM}/wrappers/ruby-3.3.14:/usr/bin" }
      env = ProjectEnv.for(@dir, base: runner)

      %w[BUNDLE_GEMFILE BUNDLER_ORIG_PATH RUBYOPT RUBYLIB GEM_HOME RAILS_ENV DATABASE_HOST REDIS_URL].each do |k|
        assert env.key?(k), "#{k} should be unset"
        assert_nil env[k]
      end
      assert_not env.key?("HOME")
      assert_not_includes env["PATH"], "ruby-3.3.14"
      assert_includes env["PATH"], "/usr/bin"
      assert env["PATH"].start_with?(wrapper) if File.directory?(wrapper)
    end

    test "rspec repos get rspec, minitest repos get bin/rails test, both with lint" do
      touch("Gemfile")
      touch("bin/rubocop")
      touch("bin/rails")
      assert_equal "bin/rails test", ProjectEnv.commands(@dir)[:test]
      FileUtils.mkdir_p(File.join(@dir, "spec"))
      assert_equal ["bundle exec rspec", "bin/rubocop"], ProjectEnv.suite(@dir)
      assert_equal ["Bash(bundle exec rspec:*)", "Bash(bin/rubocop:*)"], ProjectEnv.allowed(@dir)
    end

    test "node repos use their package scripts; unknown repos get no briefing" do
      assert_equal "", ProjectEnv.briefing(@dir)
      touch("package.json", { scripts: { test: "jest" } }.to_json)
      assert_equal ["npm test"], ProjectEnv.suite(@dir)
    end

    test "the briefing names the exact command and forbids probing the env" do
      touch("Gemfile")
      FileUtils.mkdir_p(File.join(@dir, "spec"))
      text = ProjectEnv.briefing(@dir)
      assert_includes text, "`bundle exec rspec <paths>`"
      assert_includes text, "Do not probe the environment"
    end

    test "links only git-ignored shared files into a worktree" do
      repo = File.join(@dir, "repo")
      tree = File.join(@dir, "tree")
      FileUtils.mkdir_p([File.join(repo, "config"), File.join(tree, "config")])
      File.write(File.join(repo, ".env"), "A=1")
      File.write(File.join(repo, "config/master.key"), "k")
      File.write(File.join(repo, ".env.example"), "A=")
      ignored = %w[.env config/master.key]
      ProjectEnv.link_shared(repo, tree, git: ->(_cwd, *args) { ["", ignored.include?(args.last)] })

      assert File.symlink?(File.join(tree, ".env"))
      assert File.symlink?(File.join(tree, "config/master.key"))
      assert_not File.exist?(File.join(tree, ".env.example"))
    end
  end
end
