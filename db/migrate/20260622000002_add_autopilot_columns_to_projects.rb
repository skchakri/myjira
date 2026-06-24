# Project Board, Phase 0. Per-project autopilot controls: a master enable (off by
# default — opt in per folder), a pause toggle, and a daily launch cap with a
# rolling per-day counter. The global stop-all kill switch lives in `settings`.
class AddAutopilotColumnsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :autopilot_enabled,   :boolean, null: false, default: false
    add_column :projects, :autopilot_paused,     :boolean, null: false, default: false
    add_column :projects, :autopilot_daily_cap,  :integer, null: false, default: 10
    add_column :projects, :autopilot_runs_count, :integer, null: false, default: 0
    add_column :projects, :autopilot_runs_on,    :date
  end
end
