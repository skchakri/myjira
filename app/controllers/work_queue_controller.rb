# Live view of the Claude Code work-queue mod's items across projects.
# Reads ~/.claude/queues/*.json; actions go to the owning CLI session over the
# command channel (WorkQueue::Dispatcher). Merging PRs runs gh here.
class WorkQueueController < ApplicationController
  before_action :load_item, except: %i[index group]

  def index
    @store = WorkQueue::Store.new
    @projects = @store.projects
    WorkQueue::PullRequests.new.prefetch(@projects.values.flatten.select(&:open?).map(&:pr))
    @item = @store.find(params[:item]) if params[:item].present?
    return unless @item

    @context = WorkQueue::ItemContext.new(@item, store: @store)
    @entries = WorkQueue::Transcript.new.parse_file(@context.transcript_path).first
  end

  def run
    respond_with_dispatch(dispatcher.run_now, "Run now sent for ##{@item.n}")
  end

  def answer
    index = params[:index].to_i
    text = params[:text].to_s.strip
    return toast("Pick an option or type an answer", :error) if text.blank?

    result = dispatcher.answer(index, text)
    if result.sent
      WorkQueue::Broadcaster.log_note(@item.agent, "Q: #{@item.questions[index]&.q}\nA: #{text}")
    end
    respond_with_dispatch(result, "Answer sent to ##{@item.n}")
  end

  def instruct
    text = params[:text].to_s.strip
    return toast("Type an instruction first", :error) if text.blank?

    respond_with_dispatch(dispatcher.instruct(text), "Instruction sent to ##{@item.n}")
  end

  # Multi-select → fold into the lowest-numbered (or chosen) item, per project.
  def group
    store = WorkQueue::Store.new
    items = Array(params[:keys]).filter_map { |k| store.find(k) }
    return toast("Select at least two items from the same project", :error) if items.size < 2 || items.map(&:slug).uniq.size > 1

    target = items.find { |i| i.n == params[:target].to_i } || items.min_by(&:n)
    others = (items - [target]).map(&:n)
    respond_with_dispatch(WorkQueue::Dispatcher.new(target).merge_into(target.n, others),
                          "Grouping #{others.map { |n| "##{n}" }.join(', ')} into ##{target.n}")
  end

  def merge_pr
    result = WorkQueue::PullRequests.new.merge(@item.pr, target: merge_target)
    finish_merge(result, [@item.pr])
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

  def dispatcher = WorkQueue::Dispatcher.new(@item)
  def merge_target = params[:target] == "main" ? "main" : "base"

  def finish_merge(result, prs)
    log = result.steps.map { |s| "#{s[:ok] ? 'ok' : 'FAILED'}  #{s[:cmd]}\n#{s[:out]}" }.join("\n")
    WorkQueue::Broadcaster.log_note(@item.agent, "Merge (#{merge_target}):\n#{log}")
    return toast("Merge failed: #{result.steps.last&.dig(:out).to_s.truncate(160)}", :error) unless result.ok

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

  def toast(message, level, copy: nil)
    render turbo_stream: turbo_stream.append("wq_toasts", partial: "work_queue/toast",
                                                          locals: { message: message, level: level, copy: copy })
  end
end
