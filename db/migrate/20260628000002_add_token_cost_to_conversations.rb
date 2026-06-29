class AddTokenCostToConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :input_tokens,  :bigint,  default: 0, null: false
    add_column :conversations, :output_tokens, :bigint,  default: 0, null: false
    add_column :conversations, :cache_tokens,  :bigint,  default: 0, null: false
    add_column :conversations, :cost_usd,      :decimal, precision: 10, scale: 4, default: 0, null: false
  end
end
