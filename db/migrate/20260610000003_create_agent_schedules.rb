class CreateAgentSchedules < ActiveRecord::Migration[8.1]
  def change
    # A recurring trigger: "run this prompt/agent in this repo on this cron".
    # myjira owns the schedule and the cron math (fugit); the host launcher
    # daemon ticks a `due` endpoint each loop, and for every schedule whose
    # next_run_at has passed myjira files a SessionLaunch (which the daemon's
    # existing pending-poll then spawns) and advances next_run_at. No new
    # in-container process — the always-on daemon is the clock.
    create_table :agent_schedules, id: :uuid do |t|
      t.references :project, null: false, type: :uuid, foreign_key: true
      # Optional: the agent this schedule runs (provenance + re-resolvable prompt).
      # null → a free-form prompt schedule.
      t.references :agent, null: true, type: :uuid, foreign_key: true
      # The last launch this schedule produced (for the "last run" link).
      t.references :last_launch, null: true, type: :uuid,
                   foreign_key: { to_table: :session_launches }

      t.text   :prompt, null: false           # resolved prompt to launch with
      t.text   :task                           # the agent args, if agent-based
      t.string :model
      t.string :permission_mode

      t.string   :cron, null: false            # standard 5-field cron expression
      t.boolean  :enabled, null: false, default: true
      t.datetime :next_run_at                  # computed from cron; due when <= now
      t.datetime :last_run_at

      t.timestamps
    end

    add_index :agent_schedules, [:enabled, :next_run_at]
  end
end
