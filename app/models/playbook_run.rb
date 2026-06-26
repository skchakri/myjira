# One execution of a Playbook. Links to the SessionLaunch it spawned (and the
# AgentSchedule that drove it, for a scheduled fire). `result` records whether
# the run met the playbook's success criteria — distinct from the launch's
# spawn-outcome — and is evaluated/recorded after the run via #evaluate!.
class PlaybookRun < ApplicationRecord
  RESULTS = %w[pending passed failed inconclusive].freeze

  belongs_to :playbook
  belongs_to :session_launch, optional: true
  belongs_to :agent_schedule, optional: true

  validates :result, inclusion: { in: RESULTS }

  scope :recent, -> { order(created_at: :desc) }

  # Record the outcome of evaluating the run against its playbook's criteria.
  def evaluate!(result:, notes: nil)
    update!(result: result, notes: notes.presence, evaluated_at: Time.current)
  end
end
