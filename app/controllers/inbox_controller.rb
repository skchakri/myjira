# The home page: every Work Queue item that needs the person, across all projects,
# answerable in place. Its buttons post to the existing work_queue item endpoints.
class InboxController < ApplicationController
  def show
    @inbox = WorkQueue::Inbox.new
  end
end
