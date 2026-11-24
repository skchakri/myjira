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

  # Bar colour: green when everything is finished, the item's own tone otherwise
  # (a finished parent whose child steps are still going reads "in progress").
  def wq_progress_tone(flow, roll)
    return "ok" if roll.complete?

    flow.tone.in?(%w[ok wait]) && roll.active ? "run" : flow.tone
  end

  # Thin bar + "NN%". label: is what a screen reader hears for the bar.
  def wq_progress(percent, tone:, label:, css: nil)
    tag.span(class: ["wq-prog", "wq-prog-#{tone}", css]) do
      tag.span(tag.i(style: "width: #{percent}%"), class: "wq-prog-bar", role: "progressbar",
               aria: { valuenow: percent, valuemin: 0, valuemax: 100, label: label }) +
        tag.span("#{percent}%", class: "wq-prog-n")
    end
  end

  # "3 of 6 child steps done" for a parent (every level below it).
  def wq_kid_summary(roll)
    text = "#{roll.done} of #{pluralize(roll.total, 'child step')} done"
    roll.need_you.any? ? "#{text} · #{roll.need_you.size} need you" : text
  end

  # A finished parent with child steps still going must not read as plain "Live".
  def wq_flow_label(flow, roll)
    return flow.label unless roll.left.positive? && (flow.finished? || flow.closed?)

    "#{flow.label} · #{pluralize(roll.left, 'child step')} still in progress"
  end

  # One project's recorded runner cost, read once per page render.
  def wq_costs(slug)
    @wq_costs ||= {}
    @wq_costs[slug] ||= WorkQueue::Costs.project(slug)
  end

  # "$1.24", or "<$0.01" for a recorded cost that rounds to nothing.
  def wq_money(amount)
    amount = amount.to_f
    amount.positive? && amount < 0.005 ? "<$0.01" : number_to_currency(amount)
  end

  # The small cost tag on a card: the item's own cost, or the whole tree's for a parent.
  def wq_cost_tag(item, descendants = [])
    costs = wq_costs(item.slug)
    own = costs.item(item.n)
    tree = costs.tree(item, descendants)
    return unless tree.positive?

    title = if descendants.any?
      "Server runner cost of this task and its #{pluralize(descendants.size, 'child step')}: #{wq_money(tree)} (this task alone #{wq_money(own)}). CLI-session work is not counted."
    else
      "Server runner cost of this task. CLI-session work is not counted."
    end
    tag.span(wq_money(tree), class: "wq-cost", title: title)
  end

  def wq_copy_menu(item, context)
    render "work_queue/copy_menu", item: item, context: context
  end
end
