# Project Board, Phase 0. A tiny durable key/value store. Used for the global
# autopilot stop-all kill switch (so it survives restarts and is auditable), and
# available for any other singleton app-level flag later.
class CreateSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :settings, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :key, null: false
      t.text :value
      t.timestamps
    end
    add_index :settings, :key, unique: true
  end
end
