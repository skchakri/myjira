# Live view of the Claude Code work-queue mod's items across projects.
# Reads ~/.claude/queues/*.json; actions go to the owning CLI session over the
# command channel (WorkQueue::Dispatcher). Merging PRs runs gh here.
#
# With no listening CLI session the server takes over: QueueWriter writes the
# queue JSON (same schema, flock) and bin/work-queue-runner runs the item
# headlessly (see WorkQueue::Supervisor).
class WorkQueueController < ApplicationController
  ATTACH_TYPES = %r{\A(image/(png|jpe?g|gif|webp)|application/(pdf|json)|text/[\w.+-]+)\z}
  ATTACH_NAMES = /\.(md|txt|log|csv|json|ya?ml)\z/i
  MAX_ATTACH = 10

  MAX_ENTRIES = 400

  before_action :load_item, except: %i[index group create settings update_settings]

  # The list only. Git/PR status comes from WorkQueue::StatusCache (refreshed by
  # the watcher); the selected item's detail loads separately into the frame.
  def index
    @store = WorkQueue::Store.new
    @projects = @store.projects
    @item = @store.find(params[:item]) if params[:item].present?
  end

  # One item's log header + live log, for the wq_detail frame.
  def detail
    @context = WorkQueue::ItemContext.new(@item, store: WorkQueue::Store.new)
    @entries = if @context.server_run?
      replay(WorkQueue::RunState.stream(@item.key).last(MAX_ENTRIES * 2))
    else
      WorkQueue::Transcript.new.parse_tail(@context.transcript_path)
    end.last(MAX_ENTRIES)
    render layout: false
  end

  # Composer: new item into a project's queue (+ dropped images), optionally started.
  def create
    slug = params[:slug].to_s
    text = params[:text].to_s.strip
    return toast("Pick a project and describe the work", :error) if text.blank? || !slug.match?(/\A[A-Za-z0-9-]+\z/)

    title = text.lines.first.to_s.strip.truncate(80)
    item = writer.add(slug, title: title, description: text)
    paths = save_attachments(slug, item["n"])
    writer.update(slug, item["n"]) { |i| i["description"] += "\n\nAttached files:\n#{paths.join("\n")}" } if paths.any?
    key = "#{slug}:#{item['n']}"
    WorkQueue::RunState.set(key, { "repo" => WorkQueue::Workspace.repo_for(slug) }.compact)
    start_server(key, relay: params[:relay] == "1") if params[:start] == "1" || params[:relay] == "1"
    toast("Added ##{item['n']} to #{WorkQueue::Store.label(slug)}#{' and started' if params[:start] == '1'}", :ok)
  end

  # "＋ Add child item" in the detail pane: a typed-in follow-up of this item,
  # queued straight away (no approval) and bundled with its parent.
  def add_child
    title = params[:title].to_s.strip
    return toast("Give the child item a title", :error) if title.blank?

    item = writer.add(@item.slug, title: title, description: params[:description].to_s.strip.presence || title, parent: @item.n)
    writer.update(@item.slug, item["n"], log: "Added as a child of ##{@item.n} from myjira") do |i|
      i.delete("awaitingApproval")
      i["status"] = "queued"
    end
    key = "#{@item.slug}:#{item['n']}"
    WorkQueue::RunState.set(key, { "repo" => WorkQueue::Workspace.repo_for(@item.slug) }.compact)
    start_server(key)
    toast("Added ##{item['n']} under ##{@item.n}", :ok)
  end

  def run
    approve_for_run
    return respond_with_dispatch(dispatcher.run_now, "Run now sent for ##{@item.n}") if dispatcher.listening?

    start_server(@item.key, relay: params[:relay] == "1")
    toast(runner_note("##{@item.n} queued to run on the server"), :ok)
  end

  # "Run in Chrome": see Dispatcher#run_in_chrome (owning CLI, else a launched
  # interactive session; never the headless runner, which has no Chrome tools).
  def run_in_chrome
    approve_for_run
    result = dispatcher.run_in_chrome
    return respond_with_dispatch(result, "") unless result.sent

    id = result.launch&.session_id.to_s.first(8)
    message, level = if result.duplicate
      ["##{@item.n} already has a Claude session with Chrome (session #{id}): not launching a second one", :warn]
    elsif result.launch
      WorkQueue::Broadcaster.item_note(@item, "Run in Chrome: launched session #{id} in #{result.launch.repo_path}")
      ["Launching a Claude session with Chrome for ##{@item.n} (session #{id})", :ok]
    else
      WorkQueue::Broadcaster.item_note(@item, "Run in Chrome: browser step sent to the CLI session")
      ["Browser step sent to the CLI session for ##{@item.n}", :ok]
    end
    toast(message, level, also: chrome_run_stream)
  end

  # Explicit "needs the browser" flag: 1 = on, 0 = off (overrides detection), blank = auto.
  def browser
    value = params[:value].to_s
    if %w[0 1].include?(value)
      WorkQueue::RunState.set(@item.key, WorkQueue::BrowserStep::FLAG => value)
    else
      WorkQueue::RunState.del_fields(@item.key, WorkQueue::BrowserStep::FLAG)
    end
    toast("##{@item.n}: browser step #{{ '1' => 'on', '0' => 'off' }.fetch(value, 'auto-detect')}. Reopen the item to refresh.", :ok)
  end

  # "Resume" on a stalled item: the owning CLI session when it listens, else the server
  # runner picks it up from the phase it was on.
  def resume
    return respond_with_dispatch(dispatcher.resume, "Resume sent for ##{@item.n}") if dispatcher.listening?

    phase = WorkQueue::RunState.get(@item.key)["phase"].presence
    WorkQueue::RunState.set(@item.key, { "repo" => WorkQueue::Workspace.repo_for(@item.slug) }.compact) unless WorkQueue::RunState.server_run?(@item.key)
    WorkQueue::RunState.enqueue("start", @item.key, **{ phase: phase }.compact)
    writer.update(@item.slug, @item.n, log: "Resumed from myjira after a stall")
    toast(runner_note("##{@item.n} resumed on the server"), :ok)
  end

  def stop = runner_action("stop", "Stopping ##{@item.n}")
  def retry_run = runner_action("retry", "Retrying ##{@item.n} with a stronger model")
  def close_relay_tabs = runner_action("continue", "Asked ##{@item.n} to close its Chrome tabs",
                                       text: "Close every Chrome tab you opened for this relay (tabs_close_mcp) and confirm.")

  # Per-item model/effort override + lock.
  def model
    attrs = { "override_model" => params[:model].to_s, "override_effort" => params[:effort].to_s,
              "lock_model" => params[:lock] == "1" ? "1" : "0" }
    attrs = attrs.merge("override_model" => "", "override_effort" => "") unless WorkQueue::Router.valid?(params[:model], params[:effort])
    WorkQueue::RunState.set(@item.key, attrs)
    toast(attrs["override_model"].present? ? "##{@item.n}: #{params[:model]} / #{params[:effort]}#{' (locked)' if attrs['lock_model'] == '1'}" : "##{@item.n}: auto routing", :ok)
  end

  def settings
    @routing = WorkQueue::RunState.routing
    @projects = WorkQueue::Workspace.choices
    @slug = params[:slug].presence if params[:slug].to_s.match?(/\A[A-Za-z0-9-]+\z/)
    @rules = @slug ? WorkQueue::RunState.project(@slug)["always_allow"] : []
    @repo = @slug && WorkQueue::Workspace.repo_for(@slug)
    @packs_detected = WorkQueue::PermissionRules.pack_names(@repo)
    @packs_off = @slug ? Array(WorkQueue::RunState.project(@slug)["packs_off"]) : []
  end

  def update_settings
    table = WorkQueue::Router::PHASES.to_h do |ph|
      m, e = params.dig(:routing, ph, :model), params.dig(:routing, ph, :effort)
      [ph, WorkQueue::Router.valid?(m, e) ? { "model" => m, "effort" => e } : WorkQueue::Router::DEFAULTS[ph]]
    end
    WorkQueue::RunState.save_routing(table)
    slug = params[:slug].to_s
    notice = "Saved"
    if slug.match?(/\A[A-Za-z0-9-]+\z/) && params.key?(:rules)
      raw = Array(params[:rules]).map(&:to_s) + params[:new_rules].to_s.split("\n")
      raw -= Array(params[:delete_rules]).map(&:to_s)
      allow = WorkQueue::PermissionRules.clean(raw)
      skipped = raw.map(&:strip).compact_blank.uniq.size - allow.size
      attrs = { "always_allow" => allow }
      attrs["packs_off"] = WorkQueue::PermissionRules::PACKS.keys - Array(params[:packs]).map(&:to_s) if params[:packs_shown] == "1"
      WorkQueue::RunState.save_project(slug, attrs)
      notice = "Saved #{allow.size} rule#{'s' unless allow.size == 1}#{"; skipped #{skipped} invalid" if skipped.positive?}"
    end
    redirect_to work_queue_settings_path(slug: slug.presence), notice: notice
  end

  # One answer (index + text, from a chip or old clients) or several at once from
  # the question box: answers[i] = picked option, custom[i] = free text (wins).
  def answer
    pairs = answer_pairs
    return toast("Pick an option or type an answer", :error) if pairs.empty?

    unless dispatcher.listening?
      pairs.each { |index, text| answer_on_server(index, text) }
      return toast(runner_note("Answered task #{@item.n}"), :ok)
    end

    results = pairs.map do |index, text|
      result = dispatcher.answer(index, text)
      WorkQueue::Broadcaster.item_note(@item, "Q: #{@item.questions[index]&.q}\nA: #{text}") if result.sent
      result
    end
    respond_with_dispatch(results.find { |r| !r.sent } || results.last, "#{'Answer'.pluralize(pairs.size)} sent to task #{@item.n}")
  end

  def instruct
    text = params[:text].to_s.strip
    paths = save_attachments(@item.slug, @item.n)
    return toast("Type an instruction first", :error) if text.blank? && paths.empty?

    text = [text.presence || "See the attached files.", ("Attached files:\n#{paths.join("\n")}" if paths.any?)].compact.join("\n\n")

    text.scan(/\[wq-ref ([A-Za-z0-9-]+:\d+)\]/).flatten.uniq.each { |k| WorkQueue::RunState.relate(@item.key, k) }

    return respond_with_dispatch(dispatcher.instruct(text), "Instruction sent to ##{@item.n}") if dispatcher.listening?

    WorkQueue::Broadcaster.run_entries(@item.key, [qa_entry(text)])
    WorkQueue::RunState.append_stream(@item.key, { "note" => text, "kind" => "qa" })
    if WorkQueue::RunState.server_run?(@item.key)
      WorkQueue::RunState.enqueue("continue", @item.key, text: text)
    else
      start_server(@item.key)
      writer.update(@item.slug, @item.n, log: "Instruction: #{text.truncate(100)}") { |i| i["description"] += "\n\nInstruction: #{text}" }
    end
    toast(runner_note("Sent to ##{@item.n}"), :ok)
  end

  # Multi-select → fold into the lowest-numbered (or chosen) item, per project.
  def group
    store = WorkQueue::Store.new
    items = Array(params[:keys]).filter_map { |k| store.find(k) }
    return toast("Select at least two items from the same project", :error) if items.size < 2 || items.map(&:slug).uniq.size > 1

    target = items.find { |i| i.n == params[:target].to_i } || items.min_by(&:n)
    others = (items - [target]).map(&:n)
    label = "Grouped #{others.map { |n| "##{n}" }.join(', ')} into ##{target.n}"
    dispatch = WorkQueue::Dispatcher.new(target)
    return respond_with_dispatch(dispatch.merge_into(target.n, others), label) if dispatch.listening?

    writer.merge_into(target.slug, target.n, others)
    toast(label, :ok)
  end

  def merge_pr
    result = WorkQueue::PullRequests.new.merge(@item.pr, target: merge_target)
    finish_merge(result, [@item.pr])
  end

  # "Ready for PR": the runner bundles this item's tree now (members that are ready)
  # into its root's single PR, or adds them to that PR when it is already open.
  def ship
    return toast("##{@item.n} has nothing ready for a PR yet", :error) unless @item.ready_to_bundle? && @item.pr.blank?

    runner_action("bundle", "Bundling ##{@item.n} into its parent's PR")
  end

  # "Deploy": dispatch the repo's own Deploy workflow on main after the in-page confirm.
  def deploy
    pr = WorkQueue::PullRequests.new.fetch(@item.pr) if @item.pr.present?
    ok, message = WorkQueue::Delivery.new.deploy(pr)
    WorkQueue::Broadcaster.item_note(@item, "Deploy: #{message}")
    toast(message, ok ? :ok : :error)
  end

  def merge_chain
    store = WorkQueue::Store.new
    chain = WorkQueue::ItemContext.new(@item, store: store).chain
    result = WorkQueue::PullRequests.new.merge_chain(chain.map(&:pr), target: merge_target)
    finish_merge(result, chain.map(&:pr))
  end

  private

  def load_item
    @item = WorkQueue::Store.new.find(params[:id])
    head :not_found unless @item
  end

  ALLOW_ALL = { "once" => "Allow once", "always" => "Always allow in this project" }.freeze

  # "Allow all N": the chosen grant for every open permission question, plus
  # whatever was picked or typed for the other questions.
  def allow_all_pairs
    text = ALLOW_ALL[params[:allow_all].to_s] or return []

    @item.questions.each_with_index.filter_map do |q, i|
      [i, text] if q.open? && WorkQueue::PermissionRules.permission_question?(q.q) && q.options.include?(text)
    end
  end

  def answer_pairs
    return [[params[:index].to_i, params[:text].to_s.strip]].reject { |_, t| t.blank? } unless params.key?(:answers) || params.key?(:custom) || params.key?(:allow_all)

    picked = params.permit(answers: {})[:answers].to_h
    custom = params.permit(custom: {})[:custom].to_h
    (picked.keys | custom.keys).filter_map do |k|
      index = Integer(k, exception: false)
      text = custom[k].to_s.strip.presence || picked[k].to_s.strip
      [index, text] if index && text.present? && @item.questions[index]
    end.then { |picked_pairs| (allow_all_pairs + picked_pairs).uniq(&:first) }.sort_by(&:first)
  end

  def answer_on_server(index, text)
    note = "Q: #{@item.questions[index]&.q}\nA: #{text}"
    writer.answer(@item.slug, @item.n, index, text)
    WorkQueue::Broadcaster.run_entries(@item.key, [qa_entry(note)])
    WorkQueue::RunState.append_stream(@item.key, { "note" => note, "kind" => "qa" })
    WorkQueue::RunState.enqueue("answer", @item.key, text: text, q: @item.questions[index]&.q) if WorkQueue::RunState.server_run?(@item.key)
  end

  # Clicking Run now IS the approval: clear the flag in the queue file so the
  # card stops showing "Needs your approval" and the CLI queue tool accepts the
  # running update (it refuses to start items still awaiting approval).
  def approve_for_run
    return unless @item.awaiting_approval

    writer.update(@item.slug, @item.n, log: "Approved via Run now in myjira") do |i|
      i.delete("awaitingApproval")
      i["status"] = "queued" if i["status"] == "triage"
    end
    @item.awaiting_approval = false
  end

  def dispatcher = @dispatcher ||= WorkQueue::Dispatcher.new(@item)
  def writer = @writer ||= WorkQueue::QueueWriter.new

  def start_server(key, relay: false)
    WorkQueue::RunState.enqueue("start", key, relay: relay)
  end

  def runner_action(action, message, **extra)
    WorkQueue::RunState.enqueue(action, @item.key, **extra)
    toast(runner_note(message), :ok)
  end

  def runner_note(message)
    WorkQueue::RunState.runner ? message : "#{message}. No runner is up yet: start bin/work-queue-runner."
  end

  def qa_entry(text) = WorkQueue::Transcript::Entry.new(kind: "qa", body: text, at: Time.current.iso8601)

  # Rebuild log entries from the runner's persisted stream.
  def replay(events)
    parser = WorkQueue::Transcript.new
    events.flat_map do |ev|
      ev["line"] ? parser.parse_line(ev["line"]) : [WorkQueue::Transcript::Entry.new(kind: ev["kind"], body: ev["note"])]
    end
  end

  def save_attachments(slug, n)
    files = Array(params[:files]).select do |f|
      f.respond_to?(:content_type) && (f.content_type.to_s.match?(ATTACH_TYPES) || f.original_filename.to_s.match?(ATTACH_NAMES))
    end.first(MAX_ATTACH)
    return [] if files.empty?

    dir = WorkQueue::Store.dir.join("attachments", slug, n.to_s)
    FileUtils.mkdir_p(dir)
    files.map do |f|
      dest = dir.join(File.basename(f.original_filename.to_s).gsub(/[^\w.-]/, "_"))
      File.binwrite(dest, f.read)
      dest.to_s
    end
  end
  def merge_target = params[:target] == "main" ? "main" : "base"

  def finish_merge(result, prs)
    log = result.steps.map { |s| "#{s[:ok] ? 'ok' : 'FAILED'}  #{s[:cmd]}\n#{s[:out]}" }.join("\n")
    WorkQueue::Broadcaster.item_note(@item, "Merge (#{merge_target}):\n#{log}")
    return toast("Merge failed: #{result.steps.last&.dig(:out).to_s.truncate(160)}", :error) unless result.ok

    unless dispatcher.listening?
      ([@item] + WorkQueue::Store.new.dependencies(@item)).select { |i| prs.include?(i.pr) }.each do |i|
        writer.set_status(i.slug, i.n, "done", log: "PR merged from myjira")
      end
      return toast("Merged #{prs.size} PR#{'s' if prs.size > 1}", :ok)
    end

    dispatch = dispatcher.pr_merged(prs)
    toast("Merged #{prs.size} PR#{'s' if prs.size > 1}#{dispatch.sent ? '; session told to mark done' : ''}",
          :ok, copy: dispatch.sent ? nil : dispatch.copy)
  end

  def respond_with_dispatch(result, ok_message)
    if result.sent
      toast(ok_message, :ok)
    else
      toast("Not sent: #{result.reason}. Paste this into a CLI session in that project.", :warn, copy: result.copy)
    end
  end

  # The item's Run in Chrome control, redrawn from its fresh state.
  def chrome_run_stream
    context = WorkQueue::ItemContext.new(@item, store: WorkQueue::Store.new)
    turbo_stream.replace(WorkQueue::ChromeRun.dom_id(@item), partial: "work_queue/chrome_run", locals: { item: @item, context: context })
  end

  def toast(message, level, copy: nil, also: nil)
    render turbo_stream: [turbo_stream.append("wq_toasts", partial: "work_queue/toast",
                                                           locals: { message: message, level: level, copy: copy }), also].compact
  end
end
