# Global full-text search: a stored, generated `tsvector` column + GIN index on
# each searchable table. The expression must be IMMUTABLE for a generated column
# — the two-arg `to_tsvector('english', …)` (regconfig as a constant) and `||`
# concatenation both are; the single-arg form (which reads the session's
# default_text_search_config) would not be. Queried via the Searchable concern.
class AddSearchVectors < ActiveRecord::Migration[8.1]
  VECTORS = {
    tasks: "to_tsvector('english', " \
      "coalesce(title,'') || ' ' || coalesce(description,'') || ' ' || " \
      "coalesce(implementation_notes,'') || ' ' || coalesce(plan,'') || ' ' || " \
      "coalesce(agent_notes,''))",
    follow_up_tasks: "to_tsvector('english', " \
      "coalesce(title,'') || ' ' || coalesce(description,''))",
    # payload is the captured tool call (jsonb) — cast to text (immutable) so the
    # transcript's Bash commands, file paths, etc. are searchable too.
    conversation_messages: "to_tsvector('english', " \
      "coalesce(body,'') || ' ' || coalesce(payload::text,''))",
    test_results: "to_tsvector('english', " \
      "coalesce(notes,'') || ' ' || coalesce(actual_result,''))"
  }.freeze

  def up
    VECTORS.each do |table, expression|
      add_column table, :search_vector, :virtual, type: :tsvector, as: expression, stored: true
      add_index table, :search_vector, using: :gin, name: "index_#{table}_on_search_vector"
    end
  end

  def down
    VECTORS.each_key { |table| remove_column table, :search_vector }
  end
end
