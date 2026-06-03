class CreateSessionCommands < ActiveRecord::Migration[8.1]
  def change
    create_table :session_commands, id: :uuid do |t|
      t.references :conversation, type: :uuid, null: false, foreign_key: true
      t.text   :body, null: false           # the command/instruction to run
      t.string :status, null: false, default: "pending"  # pending → running → done/failed
      t.text   :result                       # what the session reported back
      t.string :source, default: "web"       # web | voice
      t.datetime :responded_at
      t.timestamps
    end
    add_index :session_commands, [:conversation_id, :created_at]
    add_index :session_commands, :status
  end
end
