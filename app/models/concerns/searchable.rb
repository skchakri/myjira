# Shared Postgres full-text search for any model carrying a stored `search_vector`
# generated column (see the AddSearchVectors migration). Used by the global
# /search across Task, FollowUpTask, ConversationMessage and TestResult.
#
#   Task.full_text("login 500")        # Google-style query, ranked best-first
#
# Always binds the user's query (`?`) — `websearch_to_tsquery` tolerates stray
# quotes/operators, so the raw input is safe to pass and never interpolated.
module Searchable
  extend ActiveSupport::Concern

  included do
    scope :full_text, lambda { |query|
      q = query.to_s.strip
      next none if q.blank?

      col = "#{table_name}.search_vector"
      where("#{col} @@ websearch_to_tsquery('english', ?)", q)
        .order(Arel.sql(sanitize_sql_array(
          ["ts_rank(#{col}, websearch_to_tsquery('english', ?)) DESC", q]
        )))
    }
  end
end
