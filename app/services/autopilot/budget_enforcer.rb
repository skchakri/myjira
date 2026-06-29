# Hard budget caps for autopilot/playbook runs. Swept once per orchestrator tick
# (independent of the per-project advance, so a runaway is killable even when
# autopilot is globally stopped). Reads the live $ estimate Layer A reconciles
# onto each SessionLaunch on every cost sync:
#
#   ≥ 80% of cap  → soft alert once  (worklog node + a comment on the bound task)
#   ≥ 100% of cap → hard kill        (flag over_budget, flip status → "canceling"
#                                     so the daemon's kill leg claims it, and fail
#                                     the bound board item with an over-budget note)
#
# Only launches with a non-nil budget_cap_cents are considered (caps are opt-in,
# defaulted onto board/playbook launches in SessionLaunch.queue!). The actual
# `tmux kill-session` is the host daemon's job (it polls /to_cancel); even before
# that ships, the DB state is correct — the launch is marked over-budget, the item
# is failed, and the red badge shows.
module Autopilot
  module BudgetEnforcer
    module_function

    SOFT_ALERT_RATIO = 0.8

    # Examine every in-flight capped launch and alert/kill as needed. Returns a
    # summary of what it touched. Each launch is guarded individually so one bad
    # row never aborts the sweep.
    def sweep!
      killed = []
      alerted = []
      candidates.find_each do |launch|
        cap = launch.budget_cap_cents.to_i
        next unless cap.positive?
        cost = launch.estimated_cost_cents.to_i
        if cost >= cap
          killed << launch.id if kill_over_budget!(launch)
        elsif cost >= (cap * SOFT_ALERT_RATIO) && launch.budget_alerted_at.nil?
          alerted << launch.id if soft_alert!(launch)
        end
      rescue StandardError => e
        Rails.logger.error("[budget] launch #{launch.id} sweep failed: #{e.class} #{e.message}")
      end
      { ok: true, killed: killed, alerted: alerted }
    end

    # In-flight launches that carry a cap and a known cost (so a launch with no
    # usage captured yet — nil cost — is never killed on a phantom $0).
    def candidates
      SessionLaunch.active
                   .where.not(budget_cap_cents: nil)
                   .where.not(estimated_cost_cents: nil)
    end

    # Flag the launch over-budget and hand it to the daemon's kill leg, then fail
    # the bound item. Locked + status-guarded so overlapping ticks can't double-kill.
    def kill_over_budget!(launch)
      # Skip only if already handled — note "launched" is the *running* state we
      # mean to kill (SessionLaunch#done? treats it as spawn-succeeded, which is
      # not what we want here), so guard on the explicit terminal/cancel states.
      flipped = launch.with_lock do
        next false if launch.over_budget? || %w[canceling canceled failed].include?(launch.status)
        launch.update!(over_budget: true, over_budget_at: Time.current, status: "canceling")
        true
      end
      return false unless flipped

      cap   = format_dollars(launch.budget_cap_cents)
      spent = format_dollars(launch.estimated_cost_cents)
      launch.emit_worklog("launch.over_budget", status: "failed",
        label: "Over budget — killing (spent #{spent}, cap #{cap})")
      if (task = launch.task)
        task.comments.create!(author: "autopilot",
          body: "🛑 Killed: run exceeded its #{cap} budget cap (spent #{spent}). Session is being terminated.")
        task.mark_failed!(note: "Killed: exceeded #{cap} budget cap (spent #{spent}).")
      end
      true
    end

    # Emit a one-time 80% warning. budget_alerted_at makes it idempotent across the
    # repeated ticks before the run either finishes or trips the hard cap.
    def soft_alert!(launch)
      launch.update_columns(budget_alerted_at: Time.current, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      cap   = format_dollars(launch.budget_cap_cents)
      spent = format_dollars(launch.estimated_cost_cents)
      launch.emit_worklog("launch.budget_warn", status: "waiting",
        label: "Budget 80% — #{spent} of #{cap}")
      launch.task&.comments&.create!(author: "autopilot",
        body: "⚠️ Budget 80%: this run has spent #{spent} of its #{cap} cap.")
      true
    end

    def format_dollars(cents)
      format("$%.2f", cents.to_i / 100.0)
    end
  end
end
