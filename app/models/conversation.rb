# One Claude CLI session, captured turn-by-turn. The transcript on disk
# (~/.claude/projects/<encoded-cwd>/<session>.jsonl) is the source; a Stop hook
# parses new lines after every turn and POSTs them to /api/v1/conversations/sync,
# which folds them into this record. One Conversation per CLI sessionId.
class Conversation < ApplicationRecord
  include Worklogged

  belongs_to :project
  has_many :conversation_messages, -> { order(:position, :occurred_at) }, dependent: :destroy
  # Relay tickets this CLI session filed (linked by cli_session_id). nullify on
  # destroy so closing a conversation never deletes relay history.
  has_many :browser_tasks, dependent: :nullify
  # Commands sent from the web to this (live) session, picked up by the listener.
  has_many :session_commands, dependent: :destroy
  # The web "launch" request this conversation was started from, if any (the
  # launcher daemon spun up `claude` with this session_id). nullify so deleting a
  # conversation never erases launch history.
  has_one :session_launch, dependent: :nullify

  validates :session_id, presence: true, uniqueness: true

  # A relay can be filed before this session's transcript is captured. When the
  # conversation finally lands, adopt any orphan relays that named this session.
  after_create_commit :adopt_orphan_browser_tasks

  scope :recent, -> { order(Arel.sql("COALESCE(last_message_at, created_at) DESC")) }

  # Matches Claude Code's model-deprecation / "out of policy" warnings that can
  # appear as text in captured message bodies or an explicit warnings field
  # sent by the sync hook (e.g. captured stderr from a -p / agent-frontmatter run).
  MODEL_DEPRECATION_RE = /deprecat\w*.*?model|model.*?deprecat\w*|out\s+of\s+policy/i

  # "Live" = synced a turn very recently. The Stop hook updates last_message_at
  # at the end of each turn, so this tracks sessions active in the last few min.
  LIVE_WINDOW = 8.minutes
  LIVE_STRIP_LIMIT = 12
  scope :live, -> { where("COALESCE(last_message_at, created_at) > ?", LIVE_WINDOW.ago) }

  def live?
    (last_message_at || created_at) > LIVE_WINDOW.ago
  end

  # Push the "Live now" strip to everyone on the Conversations index. Called after
  # each sync so a session appears (and its turn count / age updates) the instant a
  # turn lands, instead of waiting on the frame's slow reload. Targets the same
  # "live_sessions" frame the index renders; the periodic reload stays as the
  # stale-eviction backstop.
  def self.broadcast_live_strip!
    Turbo::StreamsChannel.broadcast_update_to(
      "live_sessions",
      target: "live_sessions",
      partial: "conversations/live_strip",
      locals: { live_conversations: live.recent.includes(:project).limit(LIVE_STRIP_LIMIT) }
    )
  end

  # Title comes from Claude's own ai-title when present; otherwise fall back to
  # the opening user prompt, then a short session label.
  def display_title
    return name if name.present?
    return title if title.present?
    first = conversation_messages.where(role: "user").order(:position).first
    return first.body.to_s.split("\n").first.to_s.truncate(80) if first
    "Session #{session_id.first(8)}"
  end

  # Unique document files this session created (Write tool → doc extension),
  # in creation order. Doubles as the allowlist for the document viewer route.
  def document_paths
    conversation_messages.where(kind: "tool").filter_map(&:document_path).uniq
  end

  # Recompute the denormalised rollup after a sync batch: counts, the "last
  # context" subline, and the distilled highlights. Done here (one extra pass
  # over this session's messages) so the index list never touches messages.
  def refresh_counts!
    prev_count = message_count.to_i
    update_columns(
      message_count: conversation_messages.count,
      last_message_at: conversation_messages.maximum(:occurred_at) || last_message_at || created_at,
      last_context: compute_last_context,
      highlights: compute_highlights,
      model_deprecated: model_deprecated | compute_model_deprecated
    )
    # One timeline node per sync batch that actually added turns, so a live
    # session's worklog fills in turn-by-turn with what it's now working on.
    if message_count.to_i > prev_count
      emit_worklog("session.turn", status: live? ? "running" : "info",
        label: last_context.presence || "Turn #{message_count}")
    end
  end

  # The most recent thing you asked for — drives the "↳ last:" subline so a long
  # session reads as what it's doing now, not the prompt it opened with.
  def compute_last_context
    msg = conversation_messages.where(role: "user", kind: "message").order(:position).last
    return nil unless msg
    line = msg.body.to_s.split("\n").map(&:strip).find(&:present?)
    line&.truncate(140)
  end

  # A few bullets of what actually happened — files edited, commits, tests,
  # commands — read off the captured tool actions. Each is { "kind", "text" };
  # kind picks a glyph in the view. Ordered result-first (commits) → activity.
  def compute_highlights
    files = []
    commits = []
    tests = []
    cmd_count = 0
    tasks = []
    webs = []

    conversation_messages.where(kind: "tool").pluck(:payload).each do |raw|
      p = raw.is_a?(Hash) ? raw : {}
      input = p["input"].is_a?(Hash) ? p["input"] : {}
      case p["tool"]
      when "Edit", "Write", "NotebookEdit"
        path = input["file_path"].presence || input["notebook_path"].presence
        files << File.basename(path.to_s) if path
      when "Bash"
        cmd = input["command"].to_s
        cmd_count += 1
        if cmd.match?(/git\s+commit/) && (m = cmd.match(/-m\s+["']([^"']+)["']/))
          commits << m[1]
        end
        tests << cmd if cmd.match?(%r{\b(rspec|bin/rspec|rails\s+test|bin/rails\s+test|bin/ci|jest|pytest|vitest|go\s+test|npm\s+(run\s+)?test|yarn\s+test)\b})
      when "Task"
        tasks << input["description"] if input["description"].present?
      when "WebFetch", "WebSearch"
        webs << (input["url"].presence || input["query"].presence)
      end
    end

    out = []
    commits.last(2).reverse_each { |c| out << { "kind" => "commit", "text" => "Committed: #{c.to_s.truncate(72)}" } }
    if files.any?
      uniq = files.uniq
      label = uniq.first(2).join(", ")
      label += " +#{uniq.size - 2} more" if uniq.size > 2
      out << { "kind" => "edit", "text" => "Edited #{uniq.size} #{'file'.pluralize(uniq.size)}: #{label}" }
    end
    out << { "kind" => "test", "text" => "Ran tests (#{tests.size}×)" } if tests.any?
    out << { "kind" => "run",  "text" => "Ran #{cmd_count} shell #{'command'.pluralize(cmd_count)}" } if cmd_count.positive?
    tasks.first(1).each { |t| out << { "kind" => "task", "text" => "Subagent: #{t.to_s.truncate(72)}" } }
    webs.compact.first(1).each { |w| out << { "kind" => "web", "text" => "Looked up: #{w.to_s.truncate(72)}" } }
    out.first(6)
  end

  private

  # Scan all message bodies for model-deprecation / out-of-policy text.
  # Called by refresh_counts! after each sync batch so the result is denormalised
  # into the conversations row — avoids N+1 queries when rendering the index cards.
  def compute_model_deprecated
    conversation_messages.where(kind: "message").pluck(:body).any? do |body|
      body.to_s.match?(MODEL_DEPRECATION_RE)
    end
  end

  def adopt_orphan_browser_tasks
    BrowserTask.where(cli_session_id: session_id, conversation_id: nil)
               .update_all(conversation_id: id)
  end
end
