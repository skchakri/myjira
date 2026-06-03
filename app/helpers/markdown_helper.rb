module MarkdownHelper
  # Render a Claude / CLI message body (markdown + fenced code blocks) to safe
  # HTML. escape_html neutralizes any raw HTML in the source, so the result is
  # safe to mark html_safe. A fresh Redcarpet instance per call — the C renderer
  # is not thread-safe to share across Puma threads.
  def markdown(text)
    return "".html_safe if text.blank?

    renderer = Redcarpet::Render::HTML.new(
      escape_html: true,
      hard_wrap: true,
      link_attributes: { target: "_blank", rel: "noopener noreferrer" }
    )
    md = Redcarpet::Markdown.new(
      renderer,
      fenced_code_blocks: true,
      no_intra_emphasis: true,   # don't italicize foo_bar_baz
      autolink: true,
      tables: true,
      strikethrough: true,
      lax_spacing: true
    )
    content_tag(:div, md.render(text.to_s).html_safe, class: "md")
  end
end
