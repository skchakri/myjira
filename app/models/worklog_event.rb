# One node on a work item's step timeline — "queued → claimed → spawned →
# working… → done/failed". Written by WorklogSubscriber when a Worklogged record
# emits via `Rails.event`. Append-only history: it is never edited and is not
# destroyed with its subject, so a finished launch/run keeps a durable worklog on
# the conversation/task page after it ages out of the live "Launching" strip.
class WorklogEvent < ApplicationRecord
  # running = active step, waiting = parked on a human/input, done/failed = terminal,
  # info = a plain informational beat. Drives the dot colour + pulse in the view.
  STATUSES = %w[running waiting done failed info].freeze
  # The web/API surface is no-auth; bound untrusted text by size, not by kind.
  MAX_LABEL = 140

  belongs_to :subject, polymorphic: true
  belongs_to :project, optional: true

  validates :name, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :chronological, -> { order(:occurred_at, :created_at) }

  # The single persistence spot, called by WorklogSubscriber. Derives project from
  # the subject when not given, truncates the label, and defaults occurred_at to now.
  def self.record!(subject:, name:, status:, label:, project: nil, payload: {}, occurred_at: nil)
    create!(
      subject: subject,
      project: project || subject.try(:project),
      name: name,
      status: status.to_s,
      label: label.to_s.truncate(MAX_LABEL),
      payload: payload.is_a?(Hash) ? payload : {},
      occurred_at: occurred_at || Time.current
    )
  end

  # Whole seconds elapsed since the previous node (for the "+3s" duration chip on
  # the timeline). nil when there's no prior node or either timestamp is missing.
  def duration_since(prev)
    return nil unless prev.respond_to?(:occurred_at) && prev&.occurred_at && occurred_at
    (occurred_at - prev.occurred_at).round
  end
end
