module Jira
  # Converts an Atlassian Document Format (ADF) body — the JSON used by Jira
  # issue descriptions and comments — into Markdown. Unknown node types degrade
  # gracefully to the text they contain, so the converter never raises.
  module AdfConverter
    module_function

    def to_markdown(node)
      return "" if node.blank?
      render(node).strip
    end

    # Render a node to a string. Block nodes manage their own spacing.
    def render(node)
      return "" if node.nil?
      case node["type"]
      when "doc"        then block_children(node)
      when "paragraph"  then inline_children(node)
      when "heading"    then "#{'#' * (node.dig('attrs', 'level') || 1)} #{inline_children(node)}"
      when "text"       then apply_marks(node["text"].to_s, node["marks"])
      when "hardBreak"  then "\n"
      when "rule"       then "---"
      when "bulletList"  then render_list(node) { "- " }
      when "orderedList" then render_list(node) { |i| "#{i + 1}. " }
      when "listItem"   then block_children(node)
      when "codeBlock"  then "```\n#{plain_text(node)}\n```"
      when "blockquote" then block_children(node).split("\n").map { |l| "> #{l}" }.join("\n")
      when "mention"    then node.dig("attrs", "text").to_s
      when "emoji"      then node.dig("attrs", "text").to_s
      when "inlineCard" then node.dig("attrs", "url").to_s
      else
        # Unknown: prefer block layout if it has block children, else inline.
        node["content"] ? block_children(node) : inline_children(node)
      end
    end

    # Join block-level children with blank lines between them.
    def block_children(node)
      Array(node["content"]).map { |c| render(c) }.reject(&:empty?).join("\n\n")
    end

    # Join inline children with no separator (text, marks, hardBreaks).
    def inline_children(node)
      Array(node["content"]).map { |c| render(c) }.join
    end

    # Render each list item, prefixing the first line with the bullet and
    # indenting continuation lines (extra paragraphs, nested lists) so multi-block
    # items don't run together. The block yields the bullet string for an index.
    def render_list(node)
      Array(node["content"]).each_with_index.map do |li, i|
        bullet = yield(i)
        indent = " " * bullet.length
        lines  = render(li).split("\n")
        first  = "#{bullet}#{lines.first}"
        rest   = lines.drop(1).map { |l| l.empty? ? "" : "#{indent}#{l}" }
        [first, *rest].join("\n")
      end.join("\n")
    end

    # Flatten any subtree to its raw text (for code blocks).
    def plain_text(node)
      return node["text"].to_s if node["type"] == "text"
      Array(node["content"]).map { |c| plain_text(c) }.join
    end

    def apply_marks(text, marks)
      Array(marks).inject(text) do |acc, mark|
        case mark["type"]
        when "strong" then "**#{acc}**"
        when "em"     then "*#{acc}*"
        when "code"   then "`#{acc}`"
        when "strike" then "~~#{acc}~~"
        when "link"   then "[#{acc}](#{mark.dig('attrs', 'href')})"
        else acc
        end
      end
    end
  end
end
