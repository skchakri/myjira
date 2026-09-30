# Per-project switch for the plan→approve→execute gate. Default true so every
# existing project keeps today's assisted (human-approves-the-plan) behavior.
# When false, the board pipeline skips the gate and runs a single combined
# `board-build` session (plan → implement → test → PR) with no human stop.
class AddApprovalGateEnabledToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :approval_gate_enabled, :boolean, default: true, null: false
  end
end
