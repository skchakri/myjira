class AddBoardEnrichmentToConversations < ActiveRecord::Migration[8.0]
  def change
    # Throttle bookkeeping for the auto board-ticket enrichment pass: when the last
    # pass ran, and how many substantive user messages had been seen at that point.
    # The next pass only fires once enough new user turns have landed (see
    # Conversation#board_enrich_due?), so re-fired syncs never re-run the claude call.
    add_column :conversations, :board_enriched_at, :datetime
    add_column :conversations, :board_enriched_count, :integer, default: 0, null: false
  end
end
