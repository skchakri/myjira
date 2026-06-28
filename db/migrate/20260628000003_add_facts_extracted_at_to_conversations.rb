# Debounce marker for project-fact extraction. The Stop hook syncs a conversation
# after every turn; we only want to re-run the (LLM) fact extraction once a
# session has settled, so ExtractProjectFactsJob stamps this and the sync
# endpoint skips re-enqueuing while it's recent. nil = never extracted.
class AddFactsExtractedAtToConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :facts_extracted_at, :datetime
  end
end
