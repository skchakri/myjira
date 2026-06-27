# An append-only step-timeline node for an in-flight (and later, finished) unit of
# work — a SessionLaunch, a board Task, a captured Conversation. Emitted off the
# Rails 8.1 structured event reporter (`Rails.event`) at each lifecycle transition,
# persisted here by WorklogSubscriber, and live-appended to the page via Turbo.
# Pure history: nothing cascades a destroy from the polymorphic subject, so the
# timeline survives as the durable worklog after the run ages out of the strip.
class CreateWorklogEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :worklog_events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :subject, polymorphic: true, type: :uuid, null: false
      t.uuid :project_id, null: true
      t.string :name, null: false                 # e.g. "launch.spawned", "board.in_review"
      t.string :status, null: false, default: "info" # running / waiting / done / failed / info
      t.string :label, null: false, default: ""   # one-line, truncated ~140 in the model
      t.jsonb :payload, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.datetime :created_at, null: false
    end

    add_index :worklog_events, [:subject_type, :subject_id, :occurred_at],
              name: "index_worklog_events_on_subject_and_time"
    add_index :worklog_events, :project_id
  end
end
