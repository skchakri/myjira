class ConversationsController < ApplicationController
  PER_PROJECT_PREVIEW = 8

  def index
    if params[:project_id].present?
      @project = Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
      @conversations = @project.conversations.recent.limit(500)
    elsif params[:view] == "flat"
      # Flat: every session as a card, newest first.
      @view = :flat
      @conversations = Conversation.recent.includes(:project).limit(300)
    else
      # Default: grouped by folder (client), folders ordered by latest activity.
      @view = :grouped
      @grouped = Conversation.recent.includes(:project).group_by(&:project)
    end
  end

  # Auto-refreshing "Live now" strip (loaded into a Turbo Frame on the index).
  def live
    @live_conversations = Conversation.live.recent.includes(:project).limit(12)
    render layout: false
  end

  def show
    @conversation = Conversation.find(params[:id])
    @project = @conversation.project
    @messages = @conversation.conversation_messages.to_a
    @commands = @conversation.session_commands.recent.limit(50)
  end

  # Kick off a short spoken-friendly summary (background → Claude CLI). The panel
  # shows a loading state immediately; the job streams the result back, and the
  # browser reads it aloud.
  def summarize
    convo = Conversation.find(params[:id])
    SummarizeConversationJob.perform_later(convo.id)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.update(
          "conversation_summary_#{convo.id}",
          partial: "conversations/summary_loading", locals: { conversation: convo }
        )
      end
      format.html { redirect_to conversation_path(convo), notice: "Summarizing…" }
    end
  end

  # Queue a command for this (live) session, optionally with attached files
  # (image / video / audio — like dropping a file into Claude CLI). The listener
  # picks it up, downloads any attachments, and runs it.
  def command
    convo = Conversation.find(params[:id])
    body  = params[:body].to_s.strip
    files = Array(params[:files]).reject { |f| f.respond_to?(:blank?) && f.blank? }
    if body.present? || files.any?
      convo.session_commands.create!(
        body: body.presence || "📎 (attached files)",
        source: params[:source].presence || "web",
        files: files
      )
    end
    respond_to do |format|
      format.turbo_stream { head :no_content }   # the new command streams in via broadcast
      format.html { redirect_to conversation_path(convo) }
    end
  end

  # Set/clear the user-given session name (blank → back to the auto title).
  # The CLI statusline picks this up by session_id.
  def rename
    convo = Conversation.find(params[:id])
    convo.update(name: params[:name].to_s.strip.presence)
    redirect_to conversation_path(convo)
  end
end
