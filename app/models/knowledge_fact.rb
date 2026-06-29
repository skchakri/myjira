# A single durable, reusable fact about a project's codebase ("auth lives in
# app/services/auth", "UUID PKs everywhere", "e2e tests in spec/e2e"), learned by
# summarizing captured CLI sessions. Facts are deduped per project on a
# normalized fingerprint and capped, so re-seeing a fact bumps its recency/count
# instead of duplicating it, and facts that stop reappearing naturally retire.
class KnowledgeFact < ApplicationRecord
  belongs_to :project

  # Per-project cap. Ordered by last_seen_at desc, the overflow (the facts that
  # have gone longest without reappearing) is pruned — frequency+recency keeps
  # the set current without manual gardening.
  MAX_FACTS = 25
  # Longest a fact body we'll store — anything past this is narrative, not a fact.
  MAX_BODY = 200

  validates :body, presence: true
  validates :fingerprint, presence: true, uniqueness: { scope: :project_id }

  scope :current, -> { order(last_seen_at: :desc, created_at: :desc) }

  # Normalize a body to its dedup key: downcased, stripped, internal whitespace
  # squeezed. "Auth lives in  app/auth" and "auth lives in app/auth" collapse.
  def self.fingerprint(body)
    body.to_s.downcase.strip.gsub(/\s+/, " ")
  end

  # Upsert a fact for a project: bump times_seen + last_seen_at when the
  # fingerprint already exists, else create it. Then prune the project back to
  # MAX_FACTS. Returns the fact, or nil for a blank/over-long body (caller junk).
  def self.record!(project:, body:, conversation: nil)
    body = body.to_s.strip
    return nil if body.blank? || body.length > MAX_BODY

    fp = fingerprint(body)
    fact = find_or_initialize_by(project_id: project.id, fingerprint: fp)
    if fact.persisted?
      fact.update!(times_seen: fact.times_seen + 1, last_seen_at: Time.current)
    else
      fact.assign_attributes(body: body, source_conversation_id: conversation&.id,
                             times_seen: 1, last_seen_at: Time.current)
      fact.save!
    end
    prune!(project)
    fact
  end

  # Keep only the MAX_FACTS most-recently-seen facts for a project; delete the
  # rest. No-op when under the cap.
  def self.prune!(project)
    ids = where(project_id: project.id).current.offset(MAX_FACTS).pluck(:id)
    where(id: ids).delete_all if ids.any?
  end
end
