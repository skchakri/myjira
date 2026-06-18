# The curated catalogue of MCP servers offered for one-click add, read from
# app/data/mcp_catalog.json. Pure data + lookup — no DB. The "Browse top servers"
# gallery renders Catalog.top(10); McpInstallsController looks an entry up by key
# (Catalog.find) and composes it (with the user's inputs) into an McpInstall.
#
# Each entry is a plain Hash (string keys) shaped like the JSON file: key, title,
# name, category, transport, command, args, url, auth ("none"|"token"|"oauth"),
# inputs[] (key/label/target/secret/default/help), default_scope, popular,
# homepage, description. See the file's top-level "note" for field semantics.
module Mcp
  module Catalog
    module_function

    PATH = Rails.root.join("app/data/mcp_catalog.json")

    # Every catalogue entry, in file order. Memoised per process; the file is
    # static, so a deploy/reload picks up edits. Call reload! to force a re-read.
    def all
      @all ||= load_entries
    end

    # The entries flagged popular, in file order — the "top servers" gallery.
    def popular
      all.select { |e| e["popular"] }
    end

    # The first n popular entries (the headline "top 10").
    def top(count = 10)
      popular.first(count)
    end

    # The rest — shown under a "More" disclosure beside the top gallery.
    def rest
      all.reject { |e| e["popular"] }
    end

    # One entry by its catalog key, or nil.
    def find(key)
      return nil if key.blank?
      all.find { |e| e["key"] == key.to_s }
    end

    # Distinct categories in file order (for grouping/filters).
    def categories
      all.map { |e| e["category"] }.compact.uniq
    end

    def reload!
      @all = nil
      all
    end

    def load_entries
      data = JSON.parse(File.read(PATH))
      Array(data["servers"]).map { |e| e.freeze }.freeze
    rescue Errno::ENOENT, JSON::ParserError => e
      Rails.logger.error("[Mcp::Catalog] could not load #{PATH}: #{e.class}: #{e.message}")
      [].freeze
    end
  end
end
