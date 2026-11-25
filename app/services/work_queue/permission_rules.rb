module WorkQueue
  # Claude Code allowedTools rules for the server runner: building a sensible
  # Bash pattern from a denied command, validating hand-edited rules, the default
  # allow packs per stack, and deciding which denied commands are safe enough to
  # grant without asking the person.
  #
  # A command is looked at in its normalised form: leading VAR=value assignments
  # and known wrappers (env, rvm <ver> do) are dropped, so
  # "PATH=… rvm 3.3.6 do bundle exec rspec x" is judged as "bundle exec rspec x".
  module PermissionRules
    # Tools whose subcommand is what matters (git push vs git status).
    SUBCOMMAND_TOOLS = %w[git gh bundle bin/rails rails rake bin/rake npm npx yarn pnpm docker kubectl kamal
                          cargo go make pip uv poetry systemctl brew apt].freeze
    WRAPPERS = %w[exec run].freeze
    RULE = /\A[A-Za-z][\w.-]*(?:__[\w.-]+)*(?:\([^()\n]{1,200}\))?\z/

    # Default allow packs. Each entry is a normalised command prefix. Nothing here
    # writes outside the worktree, pushes, deletes, installs packages, or uses the
    # network beyond read-only gh.
    PACKS = {
      "base" => {
        label: "Read-only shell, git and gh",
        marker: nil,
        prefixes: ["ls", "cat", "head", "tail", "wc", "grep", "rg", "pwd", "sort", "uniq", "diff", "file", "stat", "which", "cd",
                   "sed -n", "awk", "find", "tree", "jq",
                   "git status", "git diff", "git log", "git show", "git branch", "git rev-parse", "git ls-files", "git blame",
                   "git stash list",
                   "gh pr view", "gh pr checks", "gh pr list", "gh pr diff", "gh run view", "gh run list"]
      },
      "ruby" => {
        label: "Ruby / Rails tests and lint",
        marker: "Gemfile",
        prefixes: ["bundle exec rspec", "bundle exec rubocop", "bundle exec rails test", "bin/rails test", "bin/rubocop",
                   "bin/rspec", "rspec", "rubocop", "ruby -c"]
      },
      "node" => {
        label: "Node tests, lint and build",
        marker: "package.json",
        # Repos with plain node:test files and no root package.json (e.g. a browser extension folder).
        globs: ["*.test.{mjs,js}", "*/*.test.{mjs,js}", "*/*/*.test.{mjs,js}", "*/*/*/*.test.{mjs,js}"],
        prefixes: ["npm test", "npm run lint", "npm run test", "npm run build", "npx jest", "npx vitest", "npx eslint",
                   "npx tsc", "node --check", "node --test"]
      }
    }.freeze

    # Pack commands that are only safe without certain flags. They never get a
    # blanket allowedTools rule; each vetted command is granted by its exact text.
    GUARDS = {
      "find" => /\s-(delete|exec|execdir|ok|okdir|fprint\w*|fls)\b/,
      "sed -n" => /\s-[a-zA-Z]*i|--in-place|[;{}'"]\s*w\s|\/w\s/,
      "awk" => /system|>|\|/,
      "tree" => /\s-o\b/,
      "sort" => /\s(-o|--output)\b/,
      "git branch" => /\s(-[dDmMcCf]\b|--delete|--move|--copy|--force|--set-upstream|-u\b)/
    }.freeze

    # Never suggested as "always", never auto-ruled, never auto-granted.
    DESTRUCTIVE = [
      /\A(sudo|rm|rmdir|dd|mkfs\S*|shred|chmod|chown|kill|killall|pkill|reboot|shutdown|docker|kubectl|kamal|systemctl|truncate)\b/,
      /\A(apt|apt-get|brew|pip|pip3|gem|yarn|pnpm)\s+(install|add|remove|uninstall|upgrade|update)\b/,
      /\A(npm)\s+(install|i|ci|add|remove|uninstall|update|publish)\b/,
      /\Abundle\s+(install|update|add|remove)\b/,
      /\Agit\s+push\b.*(\s--force\S*|\s-f\b|\smain\b|\smaster\b|:main\b|:master\b)/,
      /\Agit\s+(reset\s+--hard|clean|checkout\s+--\s|restore\b|rebase\b|filter-branch|gc\b|update-ref)/,
      /\A(curl|wget)\b/,
      /\A(psql|mysql|mongosh|mongo|redis-cli|sqlite3)\b/,
      /\bDROP\s+(TABLE|DATABASE)\b|\bTRUNCATE\b|\bDELETE\s+FROM\b/i
    ].freeze

    # Commands that run arbitrary other code: judged by nothing we can see.
    OPAQUE = /\A(bash|sh|zsh|fish|eval|exec|xargs|source|\.|nohup|time|watch|ssh|scp|rsync)\b|\A(python3?|ruby|node|perl|php)\s+-(e|c)\b/

    # Substitutions, backticks and redirects to anything but /dev/null hide what really runs.
    UNSAFE_SYNTAX = /\$\(|`|<\(|>\(|<<|(?<![0-9&>])>{1,2}\s*(?!\/dev\/null)(?![&>])\S|[0-9]>{1,2}\s*(?!\/dev\/null)(?![&>])\S|\n|(?<![&>])&(?![&>0-9])/

    module_function

    # "cd /x && FOO=1 bundle exec rspec spec/a_spec.rb" → "Bash(bundle exec rspec:*)"
    def for_command(command)
      segment = first_segment(command)
      words = normalize(segment)
      return "Bash" if words.empty?
      return exact_rule(segment) || "Bash(#{words.first}:*)" if words.join(" ").match?(OPAQUE)

      # A pack command is ruled by its pack prefix ("node --test", not every "node" script).
      "Bash(#{words.first(pack_prefix_size(words)).join(' ')}:*)"
    end

    def for_denial(denial)
      name = denial["tool_name"].to_s
      name == "Bash" ? for_command(denial.dig("tool_input", "command")) : name
    end

    def valid?(rule) = rule.to_s.match?(RULE)

    def clean(rules) = Array(rules).map { |r| r.to_s.strip }.compact_blank.select { |r| valid?(r) }.uniq

    # Words of one command with leading assignments and wrappers dropped.
    #   "PATH=/a GEM_HOME=/b /home/u/.rvm/bin/rvm 3.3.6 do bundle exec rspec x" → %w[bundle exec rspec x]
    def normalize(segment)
      words = segment.to_s.strip.split
      loop do
        before = words.size
        words = words.drop_while { |w| w.match?(/\A\w+=/) }
        words = words.drop(1) if words.first == "env"
        words = words.drop(3) if File.basename(words.first.to_s) == "rvm" && words[2] == "do"
        break if words.size == before
      end
      words
    end

    # The command's parts between && || ; and |, split only outside quotes.
    def segments(command)
      parts = [+""]
      quote = nil
      chars = command.to_s.strip.chars
      i = 0
      while i < chars.size
        c = chars[i]
        two = "#{c}#{chars[i + 1]}"
        if quote
          quote = nil if c == quote
          parts.last << c
        elsif c == "\\"
          parts.last << two
          i += 1
        elsif c == "'" || c == '"'
          quote = c
          parts.last << c
        elsif %w[&& ||].include?(two)
          parts << +""
          i += 1
        elsif c == ";" || c == "|"
          parts << +""
        else
          parts.last << c
        end
        i += 1
      end
      parts.map(&:strip).compact_blank
    end

    # The command with quoted text blanked, keeping what still runs inside double quotes.
    def unquoted(command)
      command.to_s.gsub(/'[^']*'/, "''").gsub(/"((?:[^"\\]|\\.)*)"/) { Regexp.last_match(1).match?(/\$\(|`/) ? '"$("' : '""' }
    end

    def destructive?(command)
      segments(command).any? { |s| (n = normalize(s).join(" ")).match?(Regexp.union(DESTRUCTIVE)) || n.match?(OPAQUE) }
    end

    # A read / test / lint command from one of the packs, with nothing hidden in it.
    def safe?(command) = covered?(command, pack_cover(PACKS.keys))

    # Every part of the command is allowed by one of the rules (packs or the
    # project's always-allow list), judged in normalised form.
    def covered?(command, rules)
      cmd = command.to_s.strip
      return false if cmd.blank? || unquoted(cmd).match?(UNSAFE_SYNTAX) || destructive?(cmd)

      prefixes = rule_prefixes(rules)
      segments(cmd).all? { |s| segment_covered?(s, prefixes) }
    end

    # allowedTools rules that let exactly this (already vetted) command run as it
    # was typed, wrappers and all: guarded commands by exact text, the rest by the
    # raw text up to their base words. nil when it cannot be written as a rule.
    def literal_rules(command)
      rules = segments(command).reject { |s| normalize(s).first == "cd" }.map do |s|
        words = normalize(s)
        guarded?(words) ? exact_rule(s) : raw_prefix_rule(s, words)
      end
      rules.any? && rules.all? ? rules.uniq : nil
    end

    def pack_names(repo)
      PACKS.select { |_, p| p[:marker].nil? || marked?(repo, p) }.keys
    end

    def marked?(repo, pack)
      return false if repo.blank?

      File.exist?(File.join(repo, pack[:marker])) ||
        Array(pack[:globs]).any? { |g| Dir.glob(g, base: repo).any? { |f| !f.start_with?("node_modules/") } }
    end

    # "Always allow in this project" on a "Permission: Bash <cmd>?" question: saved from the
    # question itself, so the rule sticks however the answer reached the agent (the server
    # runner, a listening CLI session, or after a stall when the runner no longer holds the denial).
    def remember_answer(slug, question, answer)
      cmd = command_in(question)
      return unless answer.to_s.start_with?("Always") && cmd.present? && !destructive?(cmd)

      project = RunState.project(slug)
      attrs = { "always_allow" => (Array(project["always_allow"]) + [for_command(cmd)]).uniq }
      literal = Array(literal_rules(cmd))
      attrs["auto_allow"] = (Array(project["auto_allow"]) + literal).uniq.last(300) if literal.any?
      RunState.save_project(slug, attrs)
    end

    # Pack names in force for a project: detected for its repo and not switched off.
    def enabled_packs(slug, repo)
      off = RunState.project(slug)["packs_off"]
      pack_names(repo) - Array(off)
    end

    # "Bash(prefix:*)" for pack entries that are safe with any arguments.
    def pack_rules(names)
      names.flat_map { |n| PACKS.fetch(n)[:prefixes] }.reject { |p| GUARDS.key?(p) }.map { |p| "Bash(#{p}:*)" }
    end

    # Everything a pack covers, guarded entries included (for covered?).
    def pack_cover(names) = names.flat_map { |n| PACKS.fetch(n)[:prefixes] }.map { |p| "Bash(#{p}:*)" }

    # What the runner passes as --allowedTools for a project, beyond its built-ins.
    def allowed_for(slug, repo)
      project = RunState.project(slug)
      (pack_rules(enabled_packs(slug, repo)) + Array(project["always_allow"]) + Array(project["auto_allow"])).uniq
    end

    # Rules a denied command is checked against before asking the person.
    def cover_for(slug, repo)
      (pack_cover(enabled_packs(slug, repo)) + Array(RunState.project(slug)["always_allow"])).uniq
    end

    # "Permission: Bash ls -la?" → "ls -la"; nil for other tools or a cut-off question.
    def command_in(question)
      cmd = question.to_s[/\APermission: Bash (.+)\?\z/m, 1]
      cmd unless cmd.nil? || cmd.end_with?("...", "…")
    end

    def permission_question?(question) = question.to_s.start_with?("Permission: ")
    def safe_question?(question) = (cmd = command_in(question)).present? && safe?(cmd)

    def first_segment(command)
      command.to_s.lines.first.to_s.strip.split(/\s*(?:&&|;|\|\|)\s*/).reject { |part| part.start_with?("cd ") }.first.to_s
    end

    def base_words(words)
      take = 1
      if SUBCOMMAND_TOOLS.include?(words[0]) && words[1] && !words[1].start_with?("-")
        take = 2
        take = 3 if WRAPPERS.include?(words[1]) && words[2] && !words[2].start_with?("-")
      end
      words.first(take)
    end

    def rule_prefixes(rules)
      Array(rules).filter_map do |r|
        next "" if r == "Bash"

        r.to_s[/\ABash\((.+?)(?::\*)?\)\z/, 1]
      end
    end

    def segment_covered?(segment, prefixes)
      words = normalize(segment)
      text = words.join(" ")
      return false if text.blank?
      return false if (guard = guard_for(text)) && text.match?(guard)

      prefixes.any? { |p| p.empty? || text == p || text.start_with?("#{p} ") }
    end

    def guard_for(text)
      GUARDS.find { |prefix, _| text == prefix || text.start_with?("#{prefix} ") }&.last
    end

    def guarded?(words) = guard_for(words.join(" ")).present?

    def exact_rule(segment)
      rule = "Bash(#{segment.to_s.strip})"
      rule if valid?(rule)
    end

    # The raw text up to and including the command's base words, so the rule
    # matches what Claude Code actually sees ("PATH=… rvm 3.3.6 do bundle exec rspec").
    def raw_prefix_rule(segment, words)
      raw = segment.to_s.strip.split
      keep = raw.size - words.size + pack_prefix_size(words)
      rule = "Bash(#{raw.first(keep).join(' ')}:*)"
      rule if valid?(rule)
    end

    def pack_prefix_size(words)
      text = words.join(" ")
      hit = PACKS.values.flat_map { |p| p[:prefixes] }.select { |p| text == p || text.start_with?("#{p} ") }.max_by(&:size)
      hit ? hit.split.size : base_words(words).size
    end
  end
end
