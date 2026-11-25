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
      ([ruby_bin(path), node_bin(path)] + parts).compact.uniq.join(":")
    end

    NVM = File.join(Dir.home, ".nvm")

    # The project's Node as an nvm bin dir: .nvmrc / .node-version, else nvm's default alias
    # (followed through lts/* and friends), else the newest installed. The runner is a systemd
    # service with no nvm in its PATH, so without this `node` is "command not found" and the
    # agent falls back to an absolute path that no allow rule matches.
    def node_bin(path, nvm: NVM)
      installed = Dir.glob(File.join(nvm, "versions/node/v*")).map { |d| File.basename(d) }
      return if installed.empty?

      wanted = %w[.nvmrc .node-version].filter_map { |f| read(File.join(path, f)) }.first || nvm_alias("default", nvm)
      version = matching(installed, wanted) || installed.max_by { |v| Gem::Version.new(v.delete_prefix("v")) }
      File.join(nvm, "versions/node", version, "bin")
    end

    def nvm_alias(name, nvm)
      5.times do
        target = read(File.join(nvm, "alias", name)) or break
        name = target
      end
      name
    end

    # Newest installed version matching "24", "v24.13" or "24.13.0".
    def matching(installed, wanted)
      want = wanted.to_s.strip.delete_prefix("v")
      return if want.blank? || !want.match?(/\A\d+(\.\d+)*\z/)

      installed.select { |v| v.delete_prefix("v") == want || v.delete_prefix("v").start_with?("#{want}.") }
               .max_by { |v| Gem::Version.new(v.delete_prefix("v")) }
    end

    def read(file)
      File.read(file).strip.presence
    rescue SystemCallError
      nil
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
      c = ruby_tests(path) || node_tests(path) || {}
      c[:test] == "npm test" || !node_test_files?(path) ? c : c.merge(js_test: "node --test")
    end

    # Plain node:test files outside node_modules (a browser extension's tests, say).
    def node_test_files?(path)
      PermissionRules::PACKS.dig("node", :globs).any? { |g| Dir.glob(g, base: path).any? { |f| !f.split("/").include?("node_modules") } }
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
      [c[:test], c[:lint], c[:js_test]].compact.map { |cmd| "Bash(#{cmd}:*)" }
    end

    # Text appended to the agent's system prompt.
    def briefing(path)
      c = commands(path)
      return "" if c.empty?

      lines = ["Test and lint setup for this repo is already done: the shell has the project's own Ruby and Bundler, " \
               "RAILS_ENV is unset (test runners default to test), and git-ignored files (.env, keys, node_modules) are linked in."]
      lines << "Run tests with exactly `#{c[:test]} <paths>` (e.g. `#{c[:example] || c[:test]}`)." if c[:test]
      lines << "Lint with exactly `#{c[:lint]} <paths>`." if c[:lint]
      lines << "Run JavaScript test files with exactly `node --test <file>`." if c[:js_test]
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
