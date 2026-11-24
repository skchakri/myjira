class ConversationsController < ApplicationController
  PER_PROJECT_PREVIEW = 8

  # Folders per page in the grouped hub, and cards per page in the flat / single
  # project lists. Later pages load into a lazy turbo-frame as you scroll.
  GROUPS_PER_PAGE = 12
  PER_PAGE = 48

  def index
    @page = [params[:page].to_i, 1].max
    if params[:project_id].present?
      @project = Project.where(slug: params[:project_id]).or(Project.where(id: params[:project_id])).first!
      page_cards(@project.conversations.recent)
      @conversations.each { |c| c.association(:project).target = @project }
    elsif params[:view] == "flat"
      # Flat: every session as a card, newest first.
      @view = :flat
      page_cards(Conversation.recent.includes(:project))
    else
      # Default: grouped by folder (client), folders ordered by latest activity.
      @view = :grouped
      page_groups
    end
    render :page, layout: false if @page > 1
  end

  # Auto-refreshing "Live now" strip (loaded into a Turbo Frame on the index).
  def live
    @live_conversations = Conversation.live.recent.includes(:project).limit(Conversation::LIVE_STRIP_LIMIT)
    render layout: false
  end

  def show
    @conversation = Conversation.find(params[:id])
    @project = @conversation.project
    @messages = @conversation.conversation_messages.to_a
    @commands = @conversation.session_commands.recent.limit(50)
  rescue ActiveRecord::RecordNotFound
    # A stale link (e.g. a session that was cleaned up) shouldn't 500.
    redirect_to conversations_path, alert: "That session no longer exists."
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

    # `create` (not `create!`) so a rejected upload (too big / wrong type) shows
    # an inline message instead of a 500. A bare attachment gets a default
    # instruction so the listener has something actionable to do with it.
    command =
      if body.present? || files.any?
        convo.session_commands.create(
          body: body.presence || "Review the attached file(s).",
          source: params[:source].presence || "web",
          files: files
        )
      end
    error = command.errors.full_messages.to_sentence if command&.errors&.any?

    respond_to do |format|
      # On success the new command streams in via broadcast; this just clears any
      # stale error. On failure (422) the form keeps the user's input.
      format.turbo_stream do
        render turbo_stream: turbo_stream.update("command_error_#{convo.id}",
          partial: "session_commands/error", locals: { message: error }),
          status: (error ? :unprocessable_entity : :ok)
      end
      format.html { redirect_to conversation_path(convo), alert: error }
    end
  end

  # Open a document this session created (?path=…). Only paths recorded as
  # Write tool calls in this conversation are served — the transcript is the
  # allowlist, so this never reads arbitrary files. Markdown/text render in a
  # viewer page; HTML/PDF and friends stream inline.
  INLINE_TEXT_EXTENSIONS = %w[.md .markdown .mdx .txt .rst .adoc .csv .tsv].freeze

  # Second fence on top of the transcript allowlist: a served document must
  # also resolve (symlinks included) under one of these fixed roots.
  # Override with MYJIRA_DOCUMENT_ROOTS (colon-separated).
  DOCUMENT_ROOTS = ENV.fetch("MYJIRA_DOCUMENT_ROOTS", "/home/kalyan:/tmp").split(":").reject(&:blank?).freeze

  def self.allowed_document_path(path)
    return nil if path.blank?

    expanded = File.expand_path(path.to_s)
    resolved = File.exist?(expanded) ? File.realpath(expanded) : expanded
    root = DOCUMENT_ROOTS.find { |r| resolved.start_with?(File.join(File.expand_path(r), "")) }
    root && resolved
  end

  def document
    @conversation = Conversation.find(params[:id])
    # Match against the conversation's own records so the served path comes
    # from the DB, never straight from the request.
    recorded = @conversation.document_paths.find { |p| p == params[:path].to_s }
    @path = self.class.allowed_document_path(recorded)
    return redirect_to conversation_path(@conversation), alert: "That document isn't part of this session." unless @path

    @missing = !File.file?(@path)
    ext = File.extname(@path).downcase
    if @missing || INLINE_TEXT_EXTENSIONS.include?(ext)
      @content = @missing ? nil : File.read(@path)
      @render_markdown = %w[.md .markdown .mdx].include?(ext)
      render :document
    else
      send_file @path, disposition: "inline"
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to conversations_path, alert: "That session no longer exists."
  end

  # Set/clear the user-given session name (blank → back to the auto title).
  # The CLI statusline picks this up by session_id.
  def rename
    convo = Conversation.find(params[:id])
    convo.update(name: params[:name].to_s.strip.presence)
    redirect_to conversation_path(convo)
  end

  private

  # One page of cards plus whether another page follows (fetch one extra row).
  def page_cards(scope)
    rows = scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE + 1).to_a
    @more = rows.size > PER_PAGE
    @conversations = rows.first(PER_PAGE)
    Conversation.preload_first_user_bodies(@conversations)
  end

  # One page of folders: [project, session count, newest sessions]. Three queries
  # for the page (folders by latest activity, their projects, a ranked preview)
  # instead of loading every conversation and grouping in Ruby.
  def page_groups
    latest = "MAX(COALESCE(last_message_at, created_at))"
    rows = Conversation.group(:project_id).order(Arel.sql("#{latest} DESC"), :project_id)
                       .offset((@page - 1) * GROUPS_PER_PAGE).limit(GROUPS_PER_PAGE + 1)
                       .pluck(:project_id, Arel.sql("COUNT(*)"))
    @more = rows.size > GROUPS_PER_PAGE
    rows = rows.first(GROUPS_PER_PAGE)
    ids = rows.map(&:first)
    projects = Project.where(id: ids).index_by(&:id)
    ranked = Conversation.where(project_id: ids).select(
      "conversations.*, ROW_NUMBER() OVER (PARTITION BY project_id ORDER BY COALESCE(last_message_at, created_at) DESC) AS rn"
    )
    previews = Conversation.from(ranked, :conversations).where("rn <= ?", PER_PROJECT_PREVIEW).recent.group_by(&:project_id)
    Conversation.preload_first_user_bodies(previews.values.flatten)
    @groups = rows.filter_map do |id, count|
      project = projects[id] or next
      sessions = previews[id].to_a.each { |c| c.association(:project).target = project }
      [project, count, sessions]
    end
    global = Agent.enabled.where(scope: "global").count
    own = Agent.enabled.where(project_id: ids).where.not(scope: "global").group(:project_id).count
    @agent_counts = ids.index_with { |id| global + own[id].to_i }
  end
end
