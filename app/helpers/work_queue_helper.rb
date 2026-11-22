module WorkQueueHelper
  # Escapes text and turns "#123" into links that select that item (same project).
  def wq_linkify(text, slug, format: false)
    escaped = ERB::Util.html_escape(text.to_s)
    linked = if slug.present?
      escaped.to_str.gsub(/(?<![\w&])#(\d{1,5})\b/) do
        link_to("##{Regexp.last_match(1)}", work_queue_path(item: "#{slug}:#{Regexp.last_match(1)}"),
                class: "wq-ref", data: { turbo_frame: "wq_detail" })
      end
    else
      escaped
    end
    format ? simple_format(linked.html_safe, {}, sanitize: false) : linked.html_safe # rubocop:disable Rails/OutputSafety
  end

  # Paste-ready pointer to an item and its Claude session ("refer" or "sync").
  # The first line is a marker the instruct box recognises and links.
  def wq_reference(item, context, sync: false)
    git = context&.git
    session = context&.run&.dig("claude_session").presence || item.session
    lines = ["[wq-ref #{item.key}] ##{item.n} #{item.title}",
             "Project: #{WorkQueue::Store.label(item.slug)} · status #{item.display_status}"]
    lines << "Branch: #{git&.branch || item.branch} (base #{git&.base || '?'}#{"@#{git.base_sha}" if git&.base_sha})" if git || item.branch
    lines << "PR: #{item.pr}" if item.pr
    lines << "Summary: #{item.summary.to_s.squish.truncate(300)}" if item.summary.present?
    lines << "Session: #{session} — resume: #{"cd #{git.worktree} && " if git}claude --resume #{session}" if session
    if sync
      lines << "Instruction: read that task's latest log and its diff against its base " \
               "(#{git ? "git -C #{git.worktree} diff #{git.base}...HEAD" : 'its branch'}) and align your work with it."
    end
    lines.join("\n")
  end

  def wq_copy_menu(item, context)
    render "work_queue/copy_menu", item: item, context: context
  end
end
