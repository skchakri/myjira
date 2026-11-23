module WorkQueue
  # Claude Code allowedTools rules for the "always allow" list: building a
  # sensible Bash pattern from a denied command, and validating hand-edited rules.
  module PermissionRules
    # Tools whose subcommand is what matters (git push vs git status).
    SUBCOMMAND_TOOLS = %w[git gh bundle bin/rails rails rake bin/rake npm npx yarn pnpm docker kubectl kamal
                          cargo go make pip uv poetry systemctl brew apt].freeze
    WRAPPERS = %w[exec run].freeze
    RULE = /\A[A-Za-z][\w.-]*(?:__[\w.-]+)*(?:\([^()\n]{1,200}\))?\z/

    module_function

    # "cd /x && FOO=1 bundle exec rspec spec/a_spec.rb" → "Bash(bundle exec rspec:*)"
    def for_command(command)
      cmd = command.to_s.lines.first.to_s.strip
      cmd = cmd.split(/\s*(?:&&|;|\|\|)\s*/).reject { |part| part.start_with?("cd ") }.first.to_s
      words = cmd.split.drop_while { |w| w.match?(/\A\w+=/) }
      return "Bash" if words.empty?

      take = 1
      if SUBCOMMAND_TOOLS.include?(words[0]) && words[1] && !words[1].start_with?("-")
        take = 2
        take = 3 if WRAPPERS.include?(words[1]) && words[2] && !words[2].start_with?("-")
      end
      "Bash(#{words.first(take).join(' ')}:*)"
    end

    def for_denial(denial)
      name = denial["tool_name"].to_s
      name == "Bash" ? for_command(denial.dig("tool_input", "command")) : name
    end

    def valid?(rule) = rule.to_s.match?(RULE)

    def clean(rules) = Array(rules).map { |r| r.to_s.strip }.compact_blank.select { |r| valid?(r) }.uniq
  end
end
