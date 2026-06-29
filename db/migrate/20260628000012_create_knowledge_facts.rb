# Auto-accumulating "learned" codebase facts per project. When a captured CLI
# session wraps up, a cheap summarize pass extracts 3–8 durable facts (where
# things live, conventions, gotchas) and upserts them here, deduped on a
# normalized fingerprint. Top facts are prepended (with the static
# memory_preamble) into every subsequent launch so session N+1 skips the
# file-exploration warm-up session N already did.
class CreateKnowledgeFacts < ActiveRecord::Migration[8.1]
  def change
    create_table :knowledge_facts, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: true, index: true
      t.text :body, null: false
      # Normalized body (downcased / whitespace-squeezed) — the dedup key.
      t.string :fingerprint, null: false
      t.uuid :source_conversation_id
      t.integer :times_seen, default: 1, null: false
      t.datetime :last_seen_at
      t.timestamps
    end
    # One row per distinct fact per project; re-seeing a fact bumps it, not dupes.
    add_index :knowledge_facts, [:project_id, :fingerprint], unique: true
    add_index :knowledge_facts, [:project_id, :last_seen_at]
  end
end
