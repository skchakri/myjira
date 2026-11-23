module WorkQueue
  # Parses a Claude Code agent transcript (JSONL) into log entries for the live
  # view. An item maps to its transcript through the queue's `session` + `agent`
  # fields: ~/.claude/projects/<project>/<session>/subagents/agent-<agent>.jsonl
  # (the main session transcript, <session>.jsonl, is the fallback).
  class Transcript
    Entry = Struct.new(:kind, :id, :tool, :title, :body, :detail, :at, :tool_use_id, :error, keyword_init: true)
    MAX_BODY = 12_000

    def self.root
      Pathname(ENV.fetch("CLAUDE_PROJECTS_DIR", File.expand_path("~/.claude/projects")))
    end

    def self.path_for(item, root: self.root)
      return unless item.session.to_s.match?(/\A[\w-]+\z/)

      # The mod sometimes records several agents ("a1, a2"); the newest is last.
      agents = item.agent.to_s.split(/[,\s]+/).grep(/\A[\w-]+\z/).reverse
      agents.each do |agent|
        hit = Dir.glob(root.join("*", item.session, "subagents", "agent-#{agent}.jsonl")).first
        return hit if hit
      end
      session_path(item, root: root)
    end

    # The CLI session's own transcript: items a CLI session runs itself (no
    # subagent) log there.
    def self.session_path(item, root: self.root)
      return unless item.session.to_s.match?(/\A[\w-]+\z/)

      Dir.glob(root.join("*", "#{item.session}.jsonl")).first
    end

    # Why an item has no log, in words, for the empty log pane.
    def self.missing_reason(item)
      return "Not started yet: no CLI session or server runner has picked this item up." if item.session.blank?

      who = "Run by CLI session #{item.session.to_s.first(8)}#{" (agent #{item.agent})" if item.agent.present?}"
      "#{who}; no transcript found under #{root}. It may run on another machine, or the session has not written yet."
    end

    # The agent's latest working directory (its worktree), from the transcript tail.
    def self.cwd_for(path)
      return unless path && File.exist?(path)

      File.open(path) do |f|
        f.seek([f.size - 65_536, 0].max)
        f.read.scan(/"cwd":"((?:[^"\\]|\\.)*)"/).last&.first
      end
    end

    # Agent id from a subagent transcript path (agent-<id>.jsonl).
    def self.agent_id(path) = File.basename(path.to_s)[/\Aagent-([\w-]+)\.jsonl\z/, 1]

    # Live-stream id for a transcript: the agent id, or the session id for a
    # session transcript (<session>.jsonl).
    def self.stream_id(path) = agent_id(path) || File.basename(path.to_s)[/\A([\w-]+)\.jsonl\z/, 1]

    attr_reader :cwd

    def initialize
      @cwd = nil
    end

    # Parse whole lines; returns [entries, bytes consumed] so callers can tail.
    def parse(io_or_string)
      entries = []
      io_or_string.each_line do |line|
        break unless line.end_with?("\n")

        entries.concat(parse_line(line))
      end
      entries
    end

    def parse_file(path, from: 0)
      return [[], from] unless path && File.exist?(path)

      File.open(path) do |f|
        f.seek(from)
        data = f.read.to_s
        complete = data.rindex("\n")
        return [[], from] unless complete

        chunk = data[0..complete]
        [parse(chunk), from + chunk.bytesize]
      end
    end

    # Only the last `bytes` of a big transcript (the page shows the recent log).
    def parse_tail(path, bytes: 600_000)
      return [] unless path && File.exist?(path)

      size = File.size(path)
      return parse_file(path).first if size <= bytes

      File.open(path) do |f|
        f.seek(size - bytes)
        f.gets # drop the partial first line
        parse(f.read.to_s)
      end
    end

    def parse_line(line)
      d = JSON.parse(line)
      @cwd = d["cwd"] if d["cwd"].present?
      at = d["timestamp"]
      msg = d["message"] || {}
      content = msg["content"]
      case d["type"]
      when "user" then user_entries(content, at, d["uuid"])
      when "assistant" then assistant_entries(content, at, d["uuid"])
      else []
      end
    rescue JSON::ParserError
      []
    end

    private

    def user_entries(content, at, uuid)
      return [note("prompt", uuid, content.to_s, at)] if content.is_a?(String)

      Array(content).filter_map do |c|
        case c["type"]
        when "tool_result"
          Entry.new(kind: "result", tool_use_id: c["tool_use_id"], body: clip(result_text(c["content"])),
                    error: c["is_error"] == true, at: at)
        when "text" then note("prompt", uuid, c["text"], at)
        end
      end
    end

    def assistant_entries(content, at, uuid)
      Array(content).filter_map do |c|
        case c["type"]
        when "text" then note("note", uuid, c["text"], at) if c["text"].present?
        when "tool_use" then tool_entry(c, at)
        end
      end
    end

    def note(kind, uuid, text, at) = Entry.new(kind: kind, id: uuid, body: clip(text.to_s), at: at)

    def tool_entry(c, at)
      input = c["input"] || {}
      title, detail = describe(c["name"], input)
      Entry.new(kind: "tool", id: c["id"], tool: c["name"], title: title, detail: clip(detail), at: at)
    end

    def describe(name, input)
      case name
      when "Bash" then [input["description"].presence || input["command"].to_s.lines.first.to_s.strip.sub(/\Acd \S+ && /, "").truncate(120), input["command"]]
      when "Edit" then ["Edit #{input['file_path']}", "- #{input['old_string']}\n+ #{input['new_string']}"]
      when "Write" then ["Write #{input['file_path']}", input["content"]]
      when "Read" then ["Read #{input['file_path']}", nil]
      when "Grep", "Glob" then ["#{name} #{input['pattern']}", input["path"]]
      when "Agent" then ["Agent: #{input['description']}", input["prompt"]]
      else ["", input.present? ? JSON.pretty_generate(input) : nil]
      end
    end

    def result_text(content)
      return content.to_s unless content.is_a?(Array)

      content.map { |c| c["type"] == "text" ? c["text"] : "[#{c['type']}]" }.join("\n")
    end

    def clip(s)
      s = s.to_s
      s.length > MAX_BODY ? "#{s[0, MAX_BODY]}\n… (#{s.length - MAX_BODY} more chars)" : s
    end
  end
end
