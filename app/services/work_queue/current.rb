module WorkQueue
  # Per-request memo (reset by Rails between requests and tests).
  # repos: { queue slug => repo_path }, set by the list actions so drawing a hundred
  # cards does not ask the database for the project list a hundred times.
  class Current < ActiveSupport::CurrentAttributes
    attribute :repos
  end
end
