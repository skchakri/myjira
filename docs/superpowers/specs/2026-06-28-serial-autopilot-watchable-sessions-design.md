# Strict serial autopilot + watchable/interactive CLI sessions + per-session cost

**Date:** 2026-06-28
**Status:** Approved — ready for implementation plan

## Problem

The board autopilot is meant to run a simple flow: **pick one item → branch off
main → run it in a Claude CLI session → finish it → only then pick the next；
items that go to `waiting` stay waiting and are skipped.** It does not behave that
way:

1. **The "one at a time" guard is liveness-based, not state-based.** A project is
   treated as busy only if a session messaged in the last 8 minutes
   (`Project#current_board_launch` / `BOARD_LAUNCH_BUSY_WINDOW`). When a session
   stalls or dies, after 8 minutes it stops counting as busy and the orchestrator
   launches the *next* item on top of the still-`in_progress` one. Result: many
   items pile up `in_progress` at once (~16 observed across projects).
2. **No reconciliation when a session dies.** Nothing moves an item out of
   `in_progress` when its session ends without reporting a terminal state, so the
   item is orphaned forever and its uncommitted work is stashed by the next
   branch checkout (16 stashes observed).
3. **No way to watch or interact with the running session** from the UI, and **no
   visibility into what a session cost** (tokens / dollars).

There is no per-session token/cost capture today (`Conversation` and
`SessionLaunch` have no token/cost columns), though the capture hook already
walks each session transcript.

## Goals

- **Strict one-per-project serialization:** at most one `in_progress` item per
  project; the next item is picked only when the current leaves `in_progress`.
  Projects still run in parallel with each other.
- **Self-healing:** a dead session's item is automatically returned to the queue,
  so the state guard can never deadlock.
- **`waiting` is respected:** waiting items stay waiting (not `in_progress`, not
  `actionable`) and the flow moves to the next item.
- **Watch + interact:** a clickable browser terminal to watch the live Claude CLI
  session, type into it (answer questions, extend), and **resume** an ended
  session to ask follow-ups / see what it did.
- **Per-session cost:** capture token usage per session and show a dollar cost on
  the item and the session.

Out of scope (separate concern): hard budget caps / auto-stop on spend.

## Architecture context (existing)

- `Autopilot::Orchestrator` (`app/services/autopilot/orchestrator.rb`) ticks every
  ~60s off the daemon heartbeat. `tick_project` runs inside `project.with_lock`,
  skips when `project.inflight_board_launch?`, then `advance_project` launches the
  next step via `Board::Pipeline`.
- `Project#current_board_launch` / `#inflight_board_launch?`
  (`app/models/project.rb`) — the 8-minute-window busy check to replace.
- `Task::ACTIONABLE_STATES = %w[pending planned failed]`; `waiting` is not
  actionable. `Task::BOARD_STATES` includes `in_progress`, `waiting`, `in_review`,
  `failed`, `done`.
- `Board::Pipeline` queues a `SessionLaunch`; the host daemon
  (`~/.claude/bin/myjira_session_launcher.py`) spawns an interactive `claude` in a
  tmux window inside the repo and reports `tmux_target` + `session_id` back.
- `Board::PrSync` + `board/pr_sync` GET/POST + the daemon's
  `reconcile_board_prs()` — the existing reconciliation pattern to mirror for
  sessions.
- The capture hook `~/.claude/hooks/myjira_conversation_sync.py` reads each
  session transcript incrementally after every turn (offset-based) and already
  extracts `model`; `message.usage` (input/output/cache tokens) is available in
  the same lines but not captured.

## Data flow

```
ORCHESTRATOR (every ~60s, per active project, with_lock)
  reap handled by daemon leg below → in_progress reflects reality
  busy? = project.tasks.in_progress.exists?
    busy  → skip (one-at-a-time)
    free  → advance_project → SessionLaunch → daemon spawns claude in tmux (branch off origin/main)

DAEMON SESSION-SYNC leg (every heartbeat, mirrors pr_sync)
  GET /api/v1/board/session_sync → in_progress items + their launch tmux_target
    tmux has-session? → alive | dead
  POST results → Board::SessionSync.apply!
    dead window & still in_progress & agent never reported terminal → demote to pending (+attempt, note)
    alive → leave as is

WATCH / INTERACT
  in_progress item with a live tmux_target → "▶ Watch CLI" → http://host:TTYD_PORT/?arg=<tmux_target>
    single writable ttyd serves `tmux attach -t <arg>` → type/answer/scroll in browser
  ended session → "Continue in CLI" → SessionLaunch `claude --resume <session_id>` → new tmux window → same ttyd link

COST (capture hook, per turn)
  walk transcript → accumulate message.usage (input/output/cache tokens)
    → POST totals to /api/v1/projects/:slug/conversations/:id (or a usage endpoint)
      → Conversation stores tokens + computed cost_usd (per-model price table)
        → board item shows Σ cost across its launches' conversations
```

## Components & changes

### 1. State-based serialization (the core fix)
- `Project#board_busy?` → `tasks.where(board_state: "in_progress").exists?`.
- `Autopilot::Orchestrator#tick_project` — replace `next if
  project.inflight_board_launch?` with `next if project.board_busy?`. Keep the
  `with_lock` so overlapping ticks can't double-launch.
- `tick!` — the global slot math (`GLOBAL_MAX_CONCURRENT - global_inflight`)
  becomes a high safety ceiling only (default = count of active autopilot
  projects, env-overridable). Per-project serialization is the real limit.
- `current_board_launch` / `inflight_board_launch?` / `BOARD_LAUNCH_BUSY_WINDOW`
  are retained only where the UI uses them to show "which item is processing"
  (display), not as the autopilot guard. (Verify no other guard relies on them.)
- `waiting`: already excluded from `actionable` and from `in_progress`, so it
  neither blocks nor gets re-picked. No change needed; covered by a test.

### 2. Daemon session-reaper leg
- New `Board::SessionSync` service (mirrors `Board::PrSync`):
  - `work` → `{ to_check: Task.in_progress with a launched SessionLaunch →
    {task_id, launch_id, tmux_target} }`.
  - `apply!(task, alive:)` → if `alive` is false **and** the task is still
    `in_progress` (the agent never moved it to a terminal state), demote to
    `pending`, `autopilot_attempts += 1`, note "Session ended without reporting;
    re-queued."; mark the launch `status: "ended"`. If `alive`, no-op.
- `Api::V1::BoardController#session_sync` (GET → `work`) / `#session_sync_apply`
  (POST → `apply!` per result). Routes under `api/v1` next to `pr_sync`.
- Daemon: `reconcile_board_sessions()` — GET work, run `tmux has-session -t
  <target>` (and confirm the window exists) per item, POST `{results:[{task_id,
  alive}]}`. Call it on the heartbeat next to `reconcile_board_prs()`.
- Guard against reaping a just-spawned launch: only check launches whose
  `launched_at` is older than a small grace (e.g., 90s) so a window mid-spawn
  isn't flagged.

### 3. ttyd web terminal (watch + interact)
- A **single** ttyd process on the host: `ttyd --writable --port <TTYD_PORT>
  --base-path / bash -lc 'exec tmux attach -t "$0"' ` driven by the client-passed
  arg (`?arg=<tmux_target>`), bound to **127.0.0.1** only. (Exact arg-passing flag
  verified at implementation; ttyd appends URL `arg` params to the command.)
- The daemon ensures ttyd is running (start-once in `main()`, like the tmux
  session); `TTYD_PORT` env (default e.g. 7681).
- Rails: `SessionLaunch#live_terminal_url` / `Task#live_session` helper →
  `http://<MYJIRA_HOST>:<TTYD_PORT>/?arg=<tmux_target>` when the task is
  `in_progress` and the launch has a `tmux_target`.
- Board `_item.html.erb`: on `in_progress` items show **"▶ Watch CLI"** linking to
  that URL (new tab). The task page shows the same.
- **Security:** writable terminal = full shell/tmux control; localhost-only,
  documented as dev-only (myjira has no auth). Not exposed via the nginx named
  hosts.
- **Dependency:** install `ttyd` on the host (apt or static binary) as a setup
  step.

### 4. Continue / resume an ended session
- `SessionLaunch` (or Task) action **"Continue in CLI"** for items whose live
  window is gone: queue a `SessionLaunch` with prompt/command `claude --resume
  <session_id>` (same `session_id`, same repo_path), `source: "resume"`. The
  daemon spawns it in a new tmux window; the writable ttyd link then attaches.
- Controller action + route (e.g. `POST board/items/:id/continue_session` or a
  `session_launches#resume`); guarded to require an existing `session_id`.
- The existing launcher already binds `claude` to a `session_id`, so resume reuses
  that spawn path; the only new bit is the `--resume` invocation.

### 5. Per-session token cost
- Migration: add to `conversations` — `input_tokens` (bigint, default 0),
  `output_tokens` (bigint, default 0), `cache_tokens` (bigint, default 0),
  `cost_usd` (decimal, precision 10 scale 4, default 0).
- `ModelPricing` (small PORO / constant map): $/MTok input & output per model
  (Opus / Sonnet / Haiku), with cache-read/write rates; `cost_for(model, usage)`.
  Unknown model → 0 cost, tokens still stored.
- Capture hook: accumulate `message.usage` across the transcript lines it already
  reads; include running totals in its POST to myjira.
- Ingest endpoint (extend the conversation sync endpoint the hook already posts
  to, or a dedicated `conversations/:id/usage`): set token columns and recompute
  `cost_usd = ModelPricing.cost_for(model, tokens)`.
- `Task#session_cost_usd` → sum `cost_usd` over the conversations of its board
  `SessionLaunch`es. Surface on `_item.html.erb` (a small `$x.xx` chip on the
  item) and on the task page / session view.

### 6. One-time cleanup (run once, not code)
- Reset the ~16 stuck `in_progress` items → `pending` (bump nothing; just unstick)
  so the new serial flow re-picks them one at a time.
- List the 16 stashes (`git stash list`) for the user to review; do not drop them.

## Error handling

- **Reaper false positive:** the 90s spawn grace + checking actual tmux window
  existence prevents reaping a live-but-quiet session (long test runs no longer
  get reaped, because liveness is window existence, not message recency).
- **Deadlock impossibility:** if every session dies, the reaper demotes them, so
  `board_busy?` clears and the project resumes. The state guard cannot wedge.
- **ttyd down:** the "Watch CLI" link simply fails to load; the daemon restarts
  ttyd on the next heartbeat. No effect on the pipeline.
- **Resume with no session_id:** the "Continue" action is hidden/guarded.
- **Cost for unknown model:** tokens stored, `cost_usd` = 0 (no crash).
- **No double-launch:** orchestrator stays inside `project.with_lock`.

## Testing (Minitest + custom stub helper; no webmock/mocha)

- **Orchestrator:** a project with an `in_progress` item is skipped; with none, it
  advances exactly one; a `waiting` item neither blocks nor is re-picked; two
  projects each advance independently (parallel across projects).
- **`Project#board_busy?`:** true iff an `in_progress` item exists.
- **`Board::SessionSync.apply!`:** `alive:false` on an `in_progress` item demotes
  to `pending` (+1 attempt, note, launch ended); `alive:true` no-ops; an item that
  already moved to `in_review`/`done` is never demoted.
- **`session_sync` endpoints:** GET lists in_progress launches with tmux targets;
  POST applies outcomes.
- **Cost:** `ModelPricing.cost_for` for each known model and an unknown one; the
  usage endpoint stores tokens and computes `cost_usd`; `Task#session_cost_usd`
  sums across launches.
- **Helpers:** `live_terminal_url` only present for in_progress + tmux_target;
  "Continue" guarded by `session_id`.
- ttyd + the daemon legs verified manually (host infra).

## Rollout notes

- Install `ttyd` on the host; set `TTYD_PORT`.
- Edit `myjira_session_launcher.py` (session-sync leg + ttyd start) → **MUST**
  `systemctl --user restart myjira-session-launcher.service` (it runs on-disk
  code).
- Update the capture hook `myjira_conversation_sync.py` (usage accumulation).
- Run the migration in the container (`docker exec pyr-myjira bin/rails
  db:migrate`).
