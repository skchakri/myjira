class Environment < ApplicationRecord
  belongs_to :project
  has_many :tasks, dependent: :nullify
  has_many :test_runs, dependent: :nullify

  validates :name, presence: true, uniqueness: { scope: :project_id }
end
