class Task < ApplicationRecord
  STATUSES = %w[open in_progress implemented ready_for_test testing done blocked].freeze
  PRIORITIES = %w[low normal high urgent].freeze

  belongs_to :project
  belongs_to :environment, optional: true

  has_many :test_plan_tasks, dependent: :destroy
  has_many :test_plans, through: :test_plan_tasks
  has_many :test_cases, dependent: :nullify
  has_many :follow_up_tasks, dependent: :destroy

  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :priority, inclusion: { in: PRIORITIES }, allow_blank: true

  scope :recent, -> { order(created_at: :desc) }
end
