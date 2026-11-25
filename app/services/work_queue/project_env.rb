module WorkQueue
  # The runner runs under `bundle exec` inside myjira, so its own process env
  # carries myjira's Bundler setup (BUNDLE_GEMFILE, RUBYOPT, RUBYLIB, GEM_*),
  # myjira's Ruby on PATH, RAILS_ENV=development and myjira's database/Redis
  # settings. A headless agent (or the bundle suite) that inherits that env runs
  # another project's tests against myjira's Gemfile: `bundle exec rspec` fails
  # with "command not found: rspec", and the agent burns permission prompts
  # probing the environment. This builds the env a project's commands should run
  # in, and the exact test/lint commands to tell the agent.
  module ProjectEnv
    module_function

    # Variables owned by the runner's own Ruby/Rails process, never the project's.
    LEAKED = /\A(BUNDLE_|BUNDLER_|GEM_HOME\z|GEM_PATH\z|RUBYOPT\z|RUBYLIB\z|RUBY_VERSION\z|MY_RUBY_HOME\z|IRBRC\z|
                RAILS_ENV\z|RACK_ENV\z|DATABASE_|REDIS_URL\z|WORK_QUEUE_)/x
    RVM = File.join(Dir.home, ".rvm")
    # Git-ignored files a fresh worktree lacks but tests need (credentials key, built CSS, deps).
    SHARED = ["config/*.key", "config/credentials/*.key", "app/assets/builds/*", ".env*", "node_modules"].freeze

    # Env hash for Open3/spawn: nil unsets a leaked variable, PATH leads with the project's Ruby.
    def for(path, base: ENV)
      env = base.keys.grep(LEAKED).index_with { nil }
      env["PATH"] = path_for(path, base["PATH"].to_s)
      env
    end

    def path_for(path, current)
      parts = current.split(":").reject { |p| p.start_with?(RVM) }
      ruby = ruby_bin(path)
      ([ruby] + parts).compact.uniq.join(":")
    end

    # The project's .ruby-version as an rvm wrapper dir (ruby, bundle, gem with its own gemset).
    def ruby_bin(path)
      version = File.read(File.join(path, ".ruby-version")).strip
      version = "ruby-#{version}" if version.match?(/\A\d/)
      dir = File.join(RVM, "wrappers", version)
      dir if File.directory?(dir)
    rescue SystemCallError
      nil
    end

    # Exact commands for the agent, so it never has to discover how tests run.
    # { test: "bundle exec rspec", test_one: "bundle exec rspec spec/x_spec.rb", lint: "bin/rubocop", suite: [...] }
    def commands(path)
      ruby_tests(path) || node_tests(path) || {}
    end

    def ruby_tests(path)
      return unless File.exist?(File.join(path, "Gemfile"))

      lint = File.exist?(File.join(path, "bin/rubocop")) ? "bin/rubocop" : "bundle exec rubocop"
      if File.directory?(File.join(path, "spec"))
        { test: "bundle exec rspec", example: "bundle exec rspec spec/models/user_spec.rb", lint: lint }
      elsif File.exist?(File.join(path, "bin/rails"))
        { test: "bin/rails test", example: "bin/rails test test/models/user_test.rb", lint: lint }
      end
    end

    def node_tests(path)
      scripts = JSON.parse(File.read(File.join(path, "package.json")))["scripts"] || {}
      { test: ("npm test" if scripts["test"]), lint: ("npm run lint" if scripts["lint"]) }.compact.presence
    rescue SystemCallError, JSON::ParserError
      nil
    end

    # The full-suite commands the bundler runs once per bundle.
    def suite(path)
      c = commands(path)
      [c[:test], c[:lint]].compact
    end

    # allowedTools rules for exactly those commands.
    def allowed(path)
      c = commands(path)
      [c[:test], c[:lint]].compact.map { |cmd| "Bash(#{cmd}:*)" }
    end

    # Text appended to the agent's system prompt.
    def briefing(path)
      c = commands(path)
      return "" if c.empty?

      lines = ["Test and lint setup for this repo is already done: the shell has the project's own Ruby and Bundler, " \
               "RAILS_ENV is unset (test runners default to test), and git-ignored files (.env, keys, node_modules) are linked in."]
      lines << "Run tests with exactly `#{c[:test]} <paths>` (e.g. `#{c[:example] || c[:test]}`)." if c[:test]
      lines << "Lint with exactly `#{c[:lint]} <paths>`." if c[:lint]
      lines << "Do not probe the environment (no bundle check, printenv, env, rvm, ruby -e, echo $VAR): those need " \
               "permission nobody can give. If the test command itself fails to boot, stop and report its error output."
      lines.join("\n")
    end

    # Links the repo's git-ignored shared files into a worktree; never touches tracked paths.
    def link_shared(repo, path, git: ->(cwd, *args) { GitInfo.git(cwd, *args) })
      return unless File.directory?(path)

      SHARED.flat_map { |glob| Dir.glob(glob, base: repo) }.each do |rel|
        to = File.join(path, rel)
        next if File.exist?(to) || File.symlink?(to) || !File.directory?(File.dirname(to))

        File.symlink(File.join(repo, rel), to) if git.call(path, "check-ignore", "-q", rel).last
      end
    end
  end
end
