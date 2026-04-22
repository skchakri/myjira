class TestPlanTask < ApplicationRecord
  belongs_to :test_plan
  belongs_to :task

  validates :task_id, uniqueness: { scope: :test_plan_id }
end
