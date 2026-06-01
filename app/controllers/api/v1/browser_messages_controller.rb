module Api
  module V1
    # Turns in a relay thread. The CLI posts role=cli; Claude-in-Chrome posts
    # role=browser (kind=question to ask back, kind=result/done when finished).
    class BrowserMessagesController < BaseController
      before_action :find_task!

      def index
        since = params[:since].present? ? (Time.iso8601(params[:since]) rescue nil) : nil
        rel = since ? @task.browser_messages.where("created_at > ?", since) : @task.browser_messages
        render json: rel.order(:created_at).map { |m| message_json(m) }
      end

      def create
        msg = @task.browser_messages.create!(message_params)
        @task.reload
        render json: message_json(msg).merge(
          task: { id: @task.id, status: @task.status, waiting_on: waiting_on(@task) },
          next_steps: next_steps_for(@task)
        ), status: :created
      end

      private

      def find_task!
        @task = BrowserTask.find(params[:browser_task_id])
      end

      def message_params
        raw = params[:message] || params
        permitted = raw.permit(:role, :kind, :body, payload: {})
        permitted[:kind] = "message" if permitted[:kind].blank?
        permitted
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
