class CreatePushSubscriptions < ActiveRecord::Migration[8.0]
  def change
    create_table :push_subscriptions, id: :uuid do |t|
      t.string :endpoint, null: false
      t.string :p256dh,   null: false
      t.string :auth,     null: false
      t.string :user_agent
      t.timestamps
    end
    add_index :push_subscriptions, :endpoint, unique: true
  end
end
