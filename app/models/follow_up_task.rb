class FollowUpTask < ApplicationRecord
  include Searchable
  include Labelable

  SEVERITIES = %w[low medium high critical].freeze
  STATUSES   = %w[open in_progress resolved wontfix].freeze
  KINDS      = %w[gap bug enhancement regression question].freeze

  belongs_to :project
  belongs_to :task, optional: true
  belongs_to :test_result, optional: true

  validates :title, presence: true
  validates :severity, inclusion: { in: SEVERITIES }
  validates :status,   inclusion: { in: STATUSES }
  validates :kind,     inclusion: { in: KINDS }
end
