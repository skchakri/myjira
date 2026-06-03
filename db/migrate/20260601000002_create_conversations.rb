class CreateConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :conversations, id: :uuid do |t|
      t.references :project, null: false, foreign_key: true, type: :uuid
      t.string  :session_id, null: false   # Claude CLI sessionId — one conversation per session
      t.string  :title
      t.string  :cwd
      t.string  :git_branch
      t.string  :source, null: false, default: "claude-cli"
      t.string  :model
      t.datetime :started_at
      t.datetime :last_message_at
      t.integer  :message_count, null: false, default: 0
      t.timestamps
    end
    add_index :conversations, :session_id, unique: true
    add_index :conversations, :last_message_at

    create_table :conversation_messages, id: :uuid do |t|
      t.references :conversation, null: false, foreign_key: true, type: :uuid
      # Producer's stable id (transcript uuid + block suffix). Unique within a
      # conversation so re-syncs are idempotent — the server only inserts ext_ids
      # it hasn't seen.
      t.string  :ext_id, null: false
      t.string  :role, null: false              # user | assistant
      t.string  :kind, null: false, default: "message"  # message | tool
      t.text    :body
      t.jsonb   :payload, null: false, default: {}
      t.integer :position, null: false, default: 0  # chronological order within the conversation
      t.datetime :occurred_at                       # transcript timestamp
      t.timestamps
    end
    add_index :conversation_messages, [:conversation_id, :ext_id], unique: true
    add_index :conversation_messages, [:conversation_id, :position]
  end
end
