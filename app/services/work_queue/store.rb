module WorkQueue
  # Read-only view over the work-queue mod's per-project queue files
  # (~/.claude/queues/<slug>.json, written by ~/.claude/mods/work-queue).
  # The mod stays the source of truth: nothing here writes those files.
  class Store
    OPEN = %w[triage queued running blocked review].freeze
    DISPLAY_ORDER = %w[waiting running blocked pending review done].freeze

    Question = Struct.new(:q, :a, :at, :options, keyword_init: true) do
      def open? = a.nil?
    end

    Item = Struct.new(:slug, :n, :title, :description, :status, :questions, :log, :created_at,
                      :updated_at, :session, :agent, :branch, :pr, :summary, :parent,
                      :awaiting_approval, :merged_into, keyword_init: true) do
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

    def load_file(path)
      data = JSON.parse(File.read(path))
      raw = data.is_a?(Hash) ? Array(data["items"]) : Array(data)
      slug = self.class.slug_for(path)
      raw.filter_map { |h| build(slug, h) if h.is_a?(Hash) && h["n"] }
    rescue JSON::ParserError, Errno::ENOENT
      [] # mid-write or vanished; the watcher fires again on the next write
    end

    def build(slug, h)
      Item.new(
        slug: slug, n: h["n"].to_i, title: h["title"].to_s, description: h["description"].to_s,
        status: h["status"].to_s, log: Array(h["log"]),
        questions: Array(h["questions"]).map { |q| Question.new(q: q["q"], a: q["a"], at: q["at"], options: Array(q["options"])) },
        created_at: ms(h["createdAt"]), updated_at: ms(h["updatedAt"]),
        session: h["session"], agent: h["agent"], branch: h["branch"], pr: h["pr"].presence,
        summary: h["summary"], parent: h["parent"]&.to_i, awaiting_approval: h["awaitingApproval"] == true,
        merged_into: h["mergedInto"]
      )
    end

    def ms(v) = v ? Time.zone.at(v.to_i / 1000.0) : nil
  end
end
