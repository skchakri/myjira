class CreateBrowserMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :browser_messages, id: :uuid do |t|
      t.uuid   :browser_task_id, null: false
      t.string :role, null: false
      t.string :kind, null: false, default: "message"
      t.text   :body, null: false
      t.jsonb  :payload, null: false, default: {}
      t.timestamps
    end

    add_index :browser_messages, [:browser_task_id, :created_at]
    add_foreign_key :browser_messages, :browser_tasks
  end
end
