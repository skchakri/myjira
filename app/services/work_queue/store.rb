module WorkQueue
  # Read-only view over the work-queue mod's per-project queue files
  # (~/.claude/queues/<slug>.json, written by ~/.claude/mods/work-queue).
  # The mod stays the source of truth: nothing here writes those files.
  class Store
    OPEN = %w[triage queued running blocked review].freeze
    DISPLAY_ORDER = %w[waiting running pending blocked review done].freeze

    Question = Struct.new(:q, :a, :at, :options, keyword_init: true) do
      def open? = a.nil?
    end

    Item = Struct.new(:slug, :n, :title, :description, :status, :questions, :log, :created_at,
                      :updated_at, :session, :agent, :branch, :pr, :summary, :parent,
                      :awaiting_approval, :merged_into, :ready_to_bundle, :bundle, :repo, :follow_up,
                      :kind, :due, :snoozed_until, :yours_at, keyword_init: true) do
      def key = "#{slug}:#{n}"
      def dom_id = "wq_item_#{slug}_#{n}"
      def open? = OPEN.include?(status)
      def open_questions = questions.select(&:open?)

      # The six states the web view shows (the mod has eight; it folds triage/queued
      # into "pending" and splits blocked-with-open-questions out as "waiting").
      def display_status
        return "done" unless open?
        return "waiting" if open_questions.any?
        return "pending" if %w[triage queued].include?(status)

        status
      end

      def pending? = display_status == "pending"
      # Follow-up record ("followUp" in the queue JSON): {"priority" => "must"|"nice", "held" => true,
      # "admitted" => true, "by" => "person"}. See WorkQueue::ChildStarter.
      def follow_up_info = follow_up.is_a?(Hash) ? follow_up : {}
      def unstarted? = %w[triage queued].include?(status) && agent.blank?
      def held? = follow_up_info["held"] == true && unstarted?
      # A nice-to-have follow-up nobody has started or picked yet: it waits for the person's choice.
      def to_decide? = parent.present? && follow_up_info["priority"] == "nice" && follow_up_info["admitted"] != true && unstarted?
      # An errand only the person can do ("kind": "yours" in the queue JSON): no agent
      # ever runs it. due is a Date, snoozed_until a Time, yours_at when it was marked.
      def yours? = kind == "yours"
      def errand? = yours? && open?
      def snoozed? = errand? && snoozed_until.present? && snoozed_until > Time.current
      def overdue? = errand? && due.present? && due < Time.zone.today
      def due_today? = errand? && due.present? && due == Time.zone.today
      def due_now? = overdue? || due_today?
      def ready_to_bundle? = ready_to_bundle == true
      # Bundle record set by WorkQueue::Bundler: {"root", "branch", "pr"} or {"root", "failed"}.
      def bundle_info = bundle.is_a?(Hash) ? bundle : {}
      def bundle_failed? = bundle_info["failed"].present?
      # The item's own repo when it differs from its project's repo (nil otherwise).
      def foreign_repo(project_repo = Workspace.repo_for(slug))
        repo.presence unless repo.blank? || repo == project_repo
      end
      def pr_number = pr.to_s[%r{/pull/(\d+)}, 1] || pr.to_s[/\A#?(\d+)\z/, 1]
    end

    def self.dir
      Pathname(ENV.fetch("WORK_QUEUE_DIR", File.expand_path("~/.claude/queues")))
    end

    def self.slug_for(path) = File.basename(path.to_s, ".json")

    def initialize(dir: self.class.dir)
      @dir = Pathname(dir)
    end

    # { slug => [Item] } for every project file, newest activity first.
    def projects
      Dir.glob(@dir.join("*.json")).to_h { |f| [self.class.slug_for(f), load_file(f)] }
        .reject { |_, items| items.empty? }
        .sort_by { |_, items| -items.map { |i| i.updated_at.to_i }.max }
        .to_h
    end

    def items_for(slug)
      path = @dir.join("#{slug}.json")
      path.exist? ? load_file(path) : []
    end

    def all = projects.values.flatten

    def find(key)
      slug, n = key.to_s.split(":", 2)
      return if slug.blank? || n.blank? || slug.include?("/")

      items_for(slug).find { |i| i.n == n.to_i }
    end

    # Open items linked to this one: its open parent, plus its open children.
    def dependencies(item)
      siblings = items_for(item.slug)
      parent = siblings.find { |i| i.n == item.parent }
      children = siblings.select { |i| i.parent == item.n }
      ([parent] + children).compact.select(&:open?)
    end

    def self.label(slug)
      slug.sub(/\Ahome-[^-]+-/, "").sub(/\Aplatform-/, "").presence || slug
    end

    private

    # Parsed files, per process: one page render asks for the same project dozens of
    # times (every card's context), and the watcher re-reads all of them every sweep.
    # { path => [mtime, size, items] }
    PARSED = {} # rubocop:disable Style/MutableConstant
    PARSED_LOCK = Mutex.new
    # The kernel stamps mtime from a coarse clock, so a file written twice within a few
    # milliseconds can keep the same mtime. Only reuse a parse of a file that had
    # already been quiet for this long when it was read.
    SETTLED = 0.05

    def load_file(path)
      path = path.to_s
      stat = File.stat(path)
      hit = PARSED_LOCK.synchronize { PARSED[path] }
      return hit[2].map(&:dup) if hit && hit[0] == stat.mtime && hit[1] == stat.size

      read_at = Time.current
      items = parse(path)
      PARSED_LOCK.synchronize { PARSED[path] = [stat.mtime, stat.size, items] } if read_at - stat.mtime > SETTLED
      items.map(&:dup)
    rescue JSON::ParserError, Errno::ENOENT
      [] # mid-write or vanished; the watcher fires again on the next write
    end

    def parse(path)
      data = JSON.parse(File.read(path))
      raw = data.is_a?(Hash) ? Array(data["items"]) : Array(data)
      slug = self.class.slug_for(path)
      raw.filter_map { |h| build(slug, h) if h.is_a?(Hash) && h["n"] }
    end

    def build(slug, h)
      Item.new(
        slug: slug, n: h["n"].to_i, title: h["title"].to_s, description: h["description"].to_s,
        status: h["status"].to_s, log: Array(h["log"]),
        questions: Array(h["questions"]).map { |q| Question.new(q: q["q"], a: q["a"], at: q["at"], options: Array(q["options"])) },
        created_at: ms(h["createdAt"]), updated_at: ms(h["updatedAt"]),
        session: h["session"], agent: h["agent"], branch: h["branch"], pr: h["pr"].presence,
        summary: h["summary"], parent: h["parent"]&.to_i, awaiting_approval: h["awaitingApproval"] == true,
        merged_into: h["mergedInto"], ready_to_bundle: h["readyToBundle"] == true, bundle: h["bundle"],
        repo: h["repo"].presence, follow_up: h["followUp"],
        kind: h["kind"].presence, due: date(h["due"]), snoozed_until: ms(h["snoozedUntil"]), yours_at: ms(h["yoursAt"])
      )
    end

    def ms(v) = v ? Time.zone.at(v.to_i / 1000.0) : nil

    def date(v)
      Date.iso8601(v.to_s) if v.present?
    rescue ArgumentError
      nil
    end
  end
end
