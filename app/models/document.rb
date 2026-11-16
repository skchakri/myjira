# A plan, spec, report or note filed against a project — by a Claude CLI session
# (API / `relay doc`) or by hand in the web UI. Markdown body, upserted by slug so
# re-filing the same document bumps its version; every prior version is kept as
# a DocumentRevision.
class Document < ApplicationRecord
  KINDS = %w[plan spec report note].freeze

  belongs_to :project
  belongs_to :task, optional: true
  has_many :revisions, -> { order(version: :desc) }, class_name: "DocumentRevision", dependent: :delete_all

  validates :title, presence: true, length: { maximum: 200 }
  validates :slug, presence: true, uniqueness: { scope: :project_id },
                   format: { with: /\A[a-z0-9][a-z0-9-]*\z/ }, length: { maximum: 120 }
  validates :kind, inclusion: { in: KINDS }
  validates :body, length: { maximum: 2.megabytes }

  before_validation :derive_slug
  before_update :snapshot_previous_version, if: -> { will_save_change_to_body? || will_save_change_to_title? }

  scope :recent, -> { order(updated_at: :desc) }

  def self.slugify(text)
    text.to_s.downcase.strip.gsub(/[^a-z0-9]+/, "-").squeeze("-").gsub(/\A-|-\z/, "").first(120)
  end

  def to_param
    slug
  end

  private

  def derive_slug
    self.slug = self.class.slugify(slug.presence || title)
    self.slug = "doc-#{SecureRandom.hex(3)}" if slug.blank?
  end

  # Keep the outgoing text as a revision, then bump the version number.
  def snapshot_previous_version
    revisions.create!(version: version_was, title: title_was, body: body_was.to_s,
                      author: author_was, created_at: updated_at_was || Time.current)
    self.version = version_was + 1
  end
end
