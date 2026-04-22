class Project < ApplicationRecord
  has_many :environments, dependent: :destroy
  has_many :tasks, dependent: :destroy
  has_many :test_plans, dependent: :destroy
  has_many :follow_up_tasks, dependent: :destroy

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true,
    format: { with: /\A[a-z0-9][a-z0-9\-_]*\z/, message: "must be lowercase, digits, - or _" }

  before_validation :derive_slug, on: :create

  def to_param
    slug
  end

  def rollup
    {
      tasks: tasks.count,
      open_tasks: tasks.where(status: %w[open in_progress]).count,
      test_plans: test_plans.count,
      open_follow_ups: follow_up_tasks.where(status: %w[open in_progress]).count
    }
  end

  private

  def derive_slug
    return if slug.present?
    self.slug = name.to_s.downcase.strip.gsub(/[^a-z0-9]+/, "-").squeeze("-").gsub(/\A-|-\z/, "")
  end
end
