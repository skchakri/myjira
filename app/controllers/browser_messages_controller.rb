# Posting a reply from the web UI — typically the user answering a question the
# browser asked, or adding context. Both Claudes use the JSON API instead.
class BrowserMessagesController < ApplicationController
  def create
    @task = BrowserTask.find(params[:browser_task_id])
    @task.browser_messages.create!(
      role: "user",
      kind: params[:kind].presence || "message",
      body: params.require(:body)
    )
    redirect_to browser_task_path(@task)
  end
end
