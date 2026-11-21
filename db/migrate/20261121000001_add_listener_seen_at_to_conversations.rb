# When the session's `myjira-listen` listener last polled its command inbox, so
# other views (and Homey's Sessions page) can say whether a command will run.
class AddListenerSeenAtToConversations < ActiveRecord::Migration[8.0]
  def change
    add_column :conversations, :listener_seen_at, :datetime
  end
end
