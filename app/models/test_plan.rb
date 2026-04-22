class TestPlan < ApplicationRecord
  STATUSES = %w[draft active archived].freeze

  belongs_to :project
  has_many :test_plan_tasks, dependent: :destroy
  has_many :tasks, through: :test_plan_tasks
  has_many :test_cases, -> { order(:position) }, dependent: :destroy
  has_many :test_runs, dependent: :destroy

  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }

  def latest_run
    test_runs.order(started_at: :desc).first
  end
end
