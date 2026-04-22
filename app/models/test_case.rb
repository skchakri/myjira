class TestCase < ApplicationRecord
  belongs_to :test_plan
  belongs_to :task, optional: true
  has_many :test_results, dependent: :destroy

  validates :title, presence: true
  before_validation :assign_position, on: :create

  private

  def assign_position
    return if position.present? && position.positive?
    last = test_plan&.test_cases&.maximum(:position) || 0
    self.position = last + 1
  end
end
