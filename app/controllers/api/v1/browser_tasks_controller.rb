module Api
  module V1
    # The CLI ⇄ Claude-in-Chrome relay channel.
    #
    #   POST /api/v1/projects/general/browser_tasks   — CLI files an instruction
    #   POST /api/v1/browser_tasks/:id/kickoff        — release to the browser
    #   GET  /api/v1/browser_tasks/:id?wait=25&since=  — long-poll the thread (both sides watch)
    #   POST /api/v1/browser_tasks/:id/messages       — either side posts a turn
    #   GET  /api/v1/inbox?for=browser|cli            — actionable tickets across projects
    class BrowserTasksController < BaseController
      MAX_WAIT = 30

      def index
        scope =
          if params[:project_id]
            find_project!
            @project.browser_tasks
          else
            BrowserTask.all
          end
        scope = scope.where(status: params[:status]) if params[:status].present?
        render json: scope.recent.limit((params[:limit] || 100).to_i).map { |t| serialize(t) }
      end

      # Cross-project queue. `for=browser` → tickets to act on in Chrome;
      # `for=cli` → tickets with a fresh answer/question for the CLI.
      # Optional `session=<id>` scopes to one side's session: for=cli filters by
      # cli_session_id, for=browser by browser_session_id — so a session sees
      # only its own relays instead of the whole channel.
      def inbox
        for_cli = params[:for].to_s == "cli"
        scope = for_cli ? BrowserTask.for_cli : BrowserTask.for_browser
        if (sid = params[:session].presence)
          scope = scope.where(for_cli ? { cli_session_id: sid } : { browser_session_id: sid })
        end
        render json: scope.recent.includes(:project).map { |t| serialize(t) }
      end

      def show
        @task = BrowserTask.find(params[:id])
        wait  = params[:wait].to_i.clamp(0, MAX_WAIT)
        since = parse_since(params[:since])
        initial_status = @task.status

        if wait.positive?
          deadline = Time.current + wait
          loop do
            break if new_messages(@task, since).exists?
            break if @task.reload.status != initial_status
            break if Time.current >= deadline
            sleep 1.0
          end
        end

        render json: detailed(@task, since)
      end

      def create
        find_project!
        task = @project.browser_tasks.new(task_params)
        task.save!
        seed_first_message(task)
        auto_dispatch!(task) if auto_kickoff?
        render json: detailed(task).merge(next_steps: next_steps_for(task)), status: :created
      end

      def update
        task = BrowserTask.find(params[:id])
        task.assign_attributes(task_params)
        task.last_activity_at = Time.current
        task.save!
        render json: detailed(task).merge(next_steps: next_steps_for(task))
      end

      def kickoff
        task = BrowserTask.find(params[:id])
        task.touch_activity!("dispatched")
        task.browser_messages.create!(role: "system", kind: "note",
          body: "Dispatched to Claude-in-Chrome.")
        render json: detailed(task).merge(next_steps: next_steps_for(task))
      end

      def complete
        task = BrowserTask.find(params[:id])
        if (summary = params[:summary].presence)
          task.browser_messages.create!(role: params[:role].presence || "cli", kind: "note", body: summary)
        end
        task.touch_activity!("done")
        render json: detailed(task)
      end

      def cancel
        task = BrowserTask.find(params[:id])
        task.touch_activity!("cancelled")
        render json: detailed(task)
      end

      private

      def task_params
        raw = params[:browser_task] || params
        raw.permit(:title, :instructions, :target_url, :status, :priority, :source,
          :initiated_by, :cli_session_id, :browser_session_id)
      end

      # Skip the manual "Kick off" gate: file → straight to dispatched, so the
      # browser (a standing relay worker, or a one-time pasted prompt) picks it up
      # with no human click. Opt in per-ticket with auto_kickoff=true, or globally
      # with MYJIRA_RELAY_AUTO_KICKOFF set in the server env.
      def auto_kickoff?
        return true if ActiveModel::Type::Boolean.new.cast(params[:auto_kickoff])
        ENV["MYJIRA_RELAY_AUTO_KICKOFF"].present?
      end

      def auto_dispatch!(task)
        return unless task.status == "queued"
        task.touch_activity!("dispatched")
        task.browser_messages.create!(role: "system", kind: "note",
          body: "Auto-dispatched to Claude-in-Chrome (no manual kick-off).")
      end

      # On create, fold the instruction (and optional first message body) into the
      # opening turn so the browser has something to read immediately.
      def seed_first_message(task)
        body = params[:message].presence || params[:body].presence || task.instructions
        return if body.blank?
        body = "Open #{task.target_url}\n\n#{body}" if task.target_url.present? && !body.include?(task.target_url)
        role = task.source == "claude-cli" ? "cli" : (params[:role].presence || "cli")
        task.browser_messages.create!(role: role, kind: "instruction", body: body)
      end

      def parse_since(raw)
        return nil if raw.blank?
        Time.iso8601(raw.to_s)
      rescue ArgumentError
        Time.at(raw.to_f) rescue nil
      end

      def new_messages(task, since)
        rel = task.browser_messages
        since ? rel.where("created_at > ?", since) : rel
      end

      def serialize(task)
        {
          id: task.id, title: task.title, status: task.status, priority: task.priority,
          target_url: task.target_url, source: task.source, initiated_by: task.initiated_by,
          project: task.project.slug, waiting_on: waiting_on(task),
          cli_session_id: task.cli_session_id, browser_session_id: task.browser_session_id,
          conversation_id: task.conversation_id,
          message_count: task.browser_messages.size,
          last_activity_at: task.last_activity_at, created_at: task.created_at,
          urls: {
            web:   "#{base_url}/browser_tasks/#{task.id}",
            api:   "#{base_url}/api/v1/browser_tasks/#{task.id}",
            watch: "#{base_url}/api/v1/browser_tasks/#{task.id}?wait=25"
          }
        }
      end

      def detailed(task, since = nil)
        msgs = new_messages(task, since).order(:created_at).to_a
        serialize(task).merge(
          instructions: task.instructions,
          messages: msgs.map { |m| message_json(m) },
          cursor: (msgs.last&.created_at || since || task.created_at).iso8601(6)
        )
      end

      def message_json(m)
        { id: m.id, role: m.role, kind: m.kind, body: m.body, payload: m.payload,
          created_at: m.created_at.iso8601(6) }
      end

      def waiting_on(task)
        return "cli" if task.waiting_on_cli?
        return "browser" if task.waiting_on_browser?
        nil
      end
    end
  end
end
