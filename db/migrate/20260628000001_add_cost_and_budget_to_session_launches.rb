class AddCostAndBudgetToSessionLaunches < ActiveRecord::Migration[8.0]
  def change
    # Layer A — per-run usage & cost tracking. All nullable: a launch with no
    # captured usage renders "n/a", never a fake $0.00.
    change_table :session_launches, bulk: true do |t|
      t.bigint   :token_input
      t.bigint   :token_output
      t.bigint   :cache_read_tokens
      t.bigint   :cache_creation_tokens
      t.integer  :estimated_cost_cents
      t.integer  :exit_code

      # Layer B — hard budget caps & auto-stop.
      t.integer  :budget_cap_cents          # nil = uncapped (opt-in caps)
      t.integer  :max_turns                 # launch-time CLI backstop
      t.boolean  :over_budget, default: false, null: false
      t.datetime :over_budget_at
      t.datetime :budget_alerted_at         # idempotency guard for the 80% soft alert
    end

    # Daily per-project spend roll-up reads launches by day.
    add_index :session_launches, [:project_id, :created_at]

    # Per-run cap inherited by board/playbook launches (nil = uncapped).
    add_column :projects,  :autopilot_budget_cap_cents, :integer
    # Optional per-playbook override of the project cap.
    add_column :playbooks, :budget_cap_cents, :integer
  end
end
