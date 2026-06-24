# Project Board — Implementation Plan

A per-project board that turns each tracked folder into a priority queue of typed work
items, driven end-to-end by an autonomous agent pipeline (review → plan → build → test → PR),
all wired through MyJira's existing daemon, relay, test-run, and cloud-session machinery.

Status: **shipped (Phases 0–7).** Authored from an interview on 2026-06-22 and implemented the same day.

## As-built summary

Working and tested end-to-end (22 integration tests green, rubocop clean):

- **Data model** — `tasks` gained `item_type / board_state / position / agent_role / plan / pr_* / pr_diff / last_conversation_id / last_test_run_id / agent_notes / picked_up_at / finished_at / autopilot_attempts`; `projects` gained the autopilot columns; `session_launches` gained `task_id / pipeline_step`; new `settings` table for the global kill switch. Legacy `status` kept; `board_state`/`position` backfilled. House style: string columns + constant arrays (not Rails `enum`).
- **Board UI** — `GET /projects/:slug/board` (Table grouped-by-status with collapsible groups + a Kanban toggle). Native drag-to-reorder (`sortable_controller.js`) persists priority and cross-group state changes. Inline status dropdown, add-item form, Plan modal (markdown), PR modal (inline diff + GitHub link), Session link. Live updates via Turbo refresh broadcasts to `[project, :board]` (morph). Linked from the project landing pages.
- **Pipeline** — five global slash commands in `~/.claude/commands/` (`board-review`, `board-plan`, `board-engineer`, `board-debug`, `board-answer`), auto-discovered by the daemon into Agent records. `Board::Pipeline` queues each step as a `SessionLaunch` (permission_mode `bypassPermissions`, which the daemon auto-accepts); agents fetch the item and report back over the API.
- **Agent API** — `Api::V1::TasksController` permits all board fields and adds `POST .../tasks/:id/finish` (fires the test leg). `Board::TestLeg` runs the latest plan headless via `PlaywrightRunnerJob` **and** files a relay/Claude-in-Chrome visual ticket. Agents open PRs off `main` and PATCH `in_review` (green) / `failed` (red).
- **Autopilot** — `Autopilot::Orchestrator` advances each active project one step per tick, with the one-at-a-time row lock, daily cap, per-project pause, and global kill switch. Daily review gated to `>= MYJIRA_REVIEW_HOUR` UTC (default 13). Failed items park to `waiting` after `MAX_AUTOPILOT_ATTEMPTS`.
- **How it runs (no extra process / no restart)** — the orchestrator piggybacks on the heartbeat the host daemon already sends (`POST /api/v1/agent_schedules/tick`, every ~60s), so autopilot advances automatically the moment a project is enabled. A dedicated `POST /api/v1/autopilot/tick` and a board **Run next ▶** button also drive it. Autopilot is **off by default** per project.

---

## 1. Decisions (locked)

| Topic | Decision |
|---|---|
| Layout | Hybrid: ordered **table** grouped by status (collapsible), with a **Kanban** toggle. Rows draggable = priority. |
| Autopilot | **Full** — chain runs unattended down the priority queue. Per-project toggle, **off by default**. |
| Data model | **Extend the existing `Task` model** (no separate BoardItem). |
| Item types | `task`, `feature`, `issue`, `ask`. (issue = bug, feature = improvement, ask = question.) |
| Statuses | `pending`(default) → `planned` → `in_progress` → `in_review` → `done`, plus `waiting`, `hold`, `failed`. |
| Routing | **Planning agent decides** engineering vs debugger per item; `ask` → answer-only (no PR). Item type is a hint. |
| Test leg | **Both** — headless Playwright (`PlaywrightRunnerJob`) **and** relay / Claude-in-Chrome for auth'd/visual checks. |
| PR view | **Modal** with inline diff + "Open on GitHub" link. |
| Guardrails | **One item at a time** per project + per-project pause + **global stop-all** + **daily run cap**. |
| Base branch | All agent work branches off **`main`**; PRs target `main`. |
| Scope | **All** projects MyJira already tracks get a board tab; autopilot opt-in per project. |
| Sessions | Every pipeline step is a `SessionLaunch` → `Conversation`; the board's Session column opens the full transcript by `session_id`. |

---

## 2. What already exists (reused, not rebuilt)

From the codebase map (`app/models`, `app/controllers`, `config/routes.rb`):

- **Project** (`app/models/project.rb`) — deduped by `repo_path`; already `has_many :tasks, :test_plans, :conversations, :session_launches, :agents, :agent_schedules`.
- **Task** (`app/models/task.rb`) — has `status`, `priority`, `description`, `implementation_notes`, `environment_id`. **No** `item_type`, `position`, `plan`, or PR fields yet.
- **Conversation** (`app/models/conversation.rb`) — cloud sessions keyed by `session_id`, full transcript view at `GET /conversations/:id`, captures linked PRs in a `prs` JSONB column.
- **SessionLaunch.queue!** (`app/models/session_launch.rb`) — atomically creates a launch + placeholder conversation; the host daemon polls `GET /api/v1/session_launches/pending`, spawns `claude --session-id … --model … --permission-mode …` in tmux, reports back. **This is exactly how an agent "picks up" an item.**
- **AgentSchedule** (`app/models/agent_schedule.rb`) — cron + `#fire!`; daemon hits `POST /api/v1/agent_schedules/tick`. **This is the morning review agent.**
- **Agent** (`app/models/agent.rb`) — catalog of agents/skills/commands; `#launch_prompt(task)` builds the prompt. Pipeline agents register here.
- **Test stack** — `TestPlan / TestCase / TestRun / TestResult`, `RunExecutorJob` (HTTP/api_call), `PlaywrightRunnerJob` (`script/playwright_runner/index.js`, Claude-interpreted browser actions), `TestRun#propagate_status_to_tasks` (already nudges linked tasks on completion).
- **Relay** — `BrowserTask / BrowserMessage`, long-pollable, drives Claude-in-Chrome. The second test leg + a fallback execution channel.
- **UI** — Hotwire (Turbo + Stimulus), Tailwind v4, Importmap, Propshaft. Existing Stimulus controllers include `auto_reload`, `clipboard`, `client_filter`. **No sortable/drag controller yet.**

**Net new build** = board view + data-model extension + the 4-agent pipeline + autopilot orchestrator + auto-test-on-finish + plan/PR/session columns.

---

## 3. Data model changes

### 3.1 `tasks` (migration: add columns)

| Column | Type | Notes |
|---|---|---|
| `item_type` | integer (enum) | `task:0, feature:1, issue:2, ask:3`, default `task`. (Not `type` — that's Rails STI.) |
| `board_state` | integer (enum) | `pending:0, planned:1, in_progress:2, waiting:3, hold:4, in_review:5, failed:6, done:7`, default `pending`. Canonical board status. |
| `position` | integer | Ordering within a project = priority. Indexed `(project_id, position)`. |
| `agent_role` | integer (enum) | `unassigned:0, engineering:1, debugger:2, answer_only:3`. Set by the planning agent. |
| `plan` | text | Implementation plan written by the planning agent (Plan column → modal). |
| `plan_updated_at` | datetime | |
| `branch_name` | string | Feature branch off `main`. |
| `pr_url` | string | |
| `pr_number` | integer | |
| `pr_state` | string | `open / merged / closed / draft`. |
| `pr_diff` | text | Diff captured by the agent at PR-creation time (so the container needs no `gh` creds). |
| `pr_synced_at` | datetime | |
| `last_conversation_id` | uuid (FK) | Most recent session that worked this item (Session column). |
| `last_test_run_id` | uuid (FK) | Latest run (Tests column). |
| `agent_notes` | text | Last agent's status/error message (e.g. why it `failed`). |
| `picked_up_at` / `finished_at` | datetime | Lifecycle timestamps. |

Keep the legacy `status` column; a data migration backfills `board_state` from it and `position` from `created_at` order. `TestRun#propagate_status_to_tasks` is extended to drive `board_state` (`in_review` on PR, `done` on green, `failed` on red).

### 3.2 `projects` (migration: add columns)

| Column | Type | Notes |
|---|---|---|
| `autopilot_enabled` | boolean | default `false`. |
| `autopilot_paused` | boolean | default `false`. |
| `autopilot_daily_cap` | integer | default `10` launches/day. |
| `autopilot_runs_count` | integer | default `0`. |
| `autopilot_runs_on` | date | resets the counter per day. |

### 3.3 `session_launches` (migration: add column)

| Column | Type | Notes |
|---|---|---|
| `task_id` | uuid (FK, nullable) | Ties a launch (and its conversation) to the board item it worked. |
| `pipeline_step` | integer (enum) | `review, planning, engineering, debugger, answer`. |

`Task has_many :session_launches`, `has_many :conversations, through: :session_launches`.

### 3.4 Global kill switch

A tiny key/value `Setting` model (or `Rails.cache` flag) — `autopilot_stopped` boolean. One row, toggled by the global "Stop all" button.

---

## 4. Model behavior

**Task**
- `enum item_type / board_state / agent_role`; glyphs per type (issue 🐛, feature ✦, task ✔, ask ?).
- Scopes: `board_ordered` (`order(:position)`), `actionable` (pending/planned/failed), per-state scopes.
- Transitions (guarded): `mark_planned!(role:, plan:)`, `pick_up!`, `mark_waiting!`, `mark_hold!`, `mark_in_review!(pr:)`, `mark_failed!(note:)`, `mark_done!`.
- `after_update_commit` → Turbo Stream broadcast to `[project, :board]` so every open board updates live (same pattern as `TestResult#broadcast_row`).

**Project**
- `autopilot_active?` = `autopilot_enabled && !autopilot_paused && !Setting.autopilot_stopped? && under_daily_cap?`.
- `next_board_item` = first `actionable` item by `position` (FCFO).
- `inflight_launch?` = any `session_launches` in `pending/launching/launched` whose conversation is still live.
- `bump_autopilot_runs!` (resets on date rollover).

---

## 5. The agent pipeline

Five Claude commands authored under `.claude/commands/` and registered as `Agent` records (kind=command) so they appear in the launcher and can be scheduled. Each knows the MyJira API and updates its task as it works.

1. **`/board-review`** (morning cron). Reuses the existing self-improve subagents (`competitor-scout`, `trend-scout`, `ux-auditor`, `feature-gap-analyst`). Analyzes the app + market/competitor trends, reads the current `pending` list, **dedupes**, then creates new `pending` items or updates existing ones via the tasks API. One `AgentSchedule` per project, fired by the daemon's existing tick.

2. **`/board-plan`** — picks the top `pending` item (FCFO), reads it + the codebase, writes `task.plan`, sets `agent_role` (engineering / debugger / answer_only), moves it to `planned`.

3. **`/board-engineer`** — top `planned` item with role=engineering. Branches off `main`, implements, sets `in_progress` while working, then calls the **finish** endpoint (→ test leg).

4. **`/board-debug`** — role=debugger. Reads code + logs, reproduces, fixes on a branch off `main`, then finish → test leg.

5. **`/board-answer`** — role=answer_only (`ask` items). Researches, posts the answer as a comment into the session/task, sets `done`. No PR.

**Agent ⇄ MyJira contract** (small API surface the agents call):
- `PATCH /api/v1/tasks/:id` — set `board_state`, `plan`, `agent_role`, `branch_name`, `pr_*`, `pr_diff`, `agent_notes` (extend permitted params).
- `POST /api/v1/tasks/:id/finish` — agent signals "done coding" → MyJira fires the test leg (§6).
- Status/transcript flow back automatically through the existing conversation sync (Stop hook), linked by `session_id`.

---

## 6. Auto test-on-finish

On `POST /api/v1/tasks/:id/finish`:
1. Ensure a `TestPlan` for the task (agent generates tier-3 cases via the existing `myjira-test-plan` skill, or auto-create a minimal plan).
2. Create a `TestRun`; enqueue **`PlaywrightRunnerJob`** (headless UI/api cases) **and** file a **relay `BrowserTask`** for auth'd/visual cases (Claude-in-Chrome).
3. On run completion (`TestRun#propagate_status_to_tasks`, extended):
   - **green** → agent opens PR (`gh pr create --base main`), stores `pr_*` + `pr_diff` via the API, `board_state = in_review`.
   - **red** → `board_state = failed`, `agent_notes` set; item is re-pickable.
4. **Tests column**: button disabled until the item has finished at least once; auto-triggers on finish; manual re-run allowed anytime.
5. `in_review` → `done` when the PR merge is detected on PR sync. (Human merge stays the one autopilot gate; auto-merge is a later opt-in.)

---

## 7. Autopilot orchestrator

`AutopilotOrchestrator` service + `POST /api/v1/autopilot/tick` (daemon calls it every ~30–60s, alongside the existing `agent_schedules/tick`).

Per tick, for each `autopilot_active?` project:
- Skip if `inflight_launch?` (**one item at a time**).
- Else choose the next launch by board state of the top actionable item:
  - top item `failed` → re-`/board-plan` (revise) — configurable.
  - else a `planned` item exists → `/board-engineer` | `/board-debug` | `/board-answer` per `agent_role`.
  - else a `pending` item exists → `/board-plan`.
  - else nothing.
- `SessionLaunch.queue!(project:, prompt:, pipeline_step:, task:, model:, permission_mode:)`; `bump_autopilot_runs!`.

Guardrails: global `Setting.autopilot_stopped` (kill switch — in-flight sessions finish, nothing new launches), per-project `autopilot_paused`, `autopilot_daily_cap`. Concurrency-safe via the in-flight check + a DB advisory lock so a tick can't double-launch.

> **Daemon dependency:** the external `myjira_session_launcher.py` already polls `session_launches/pending` (so launches "just work") — it only needs to **also POST `/api/v1/autopilot/tick`** on its loop. Documented as a one-line daemon change.

---

## 8. UI

**Route:** `GET /projects/:project_id/board` → `BoardController#show` (also linked as a "Board" tab on the project page).

**Header:** project name + color · `[Table | Kanban]` toggle · Autopilot toggle + state ("running · working #2" / "paused") · global **Stop all** button · `[+ Add item]`.

**Table view:** collapsible groups by `board_state` (`▼ IN-PROGRESS (1)` …). Each row:
`⠿ drag · type glyph · title (→ detail drawer) · status badge (inline dropdown for manual waiting/hold/etc.) · 📋 Plan · #PR · Tests · ↗ Session`.

**Kanban view:** same rows as cards in columns by `board_state`; drag across columns changes state, order within a column = priority.

**Modals / panels:**
- **Plan** (📋) → modal showing `task.plan` (markdown) + edit.
- **PR** (#num) → modal with inline `pr_diff` + "Open on GitHub".
- **Session** (↗) → existing `GET /conversations/:id` transcript (via `last_conversation_id`).

**Stimulus (new):**
- `sortable_controller.js` — drag reorder (pin `sortablejs` via importmap, or native HTML5 DnD). On drop → `POST /projects/:id/board/reorder` with ordered ids → positions in a transaction → broadcast.
- `board_status_controller.js` — inline status dropdown.
- `modal_controller.js` — generic modal (reuse the conversation rename modal pattern if present).
- Live updates via Turbo Stream broadcasts (preferred) with `auto_reload` as fallback.

**Endpoints (web):** `board#show`, `tasks#create` (extend with `item_type`), `tasks#update` (status/plan), `board#reorder`, `tasks#plan` (modal), `tasks#pr_diff` (modal), `tasks#pick_up` (manual send-to-agent), `tasks#run_tests` (manual test trigger), `projects#autopilot` (toggle enabled/paused), `autopilot#stop_all` (global).

**Accessibility:** status badges carry text labels + `aria-label` (follows the existing status-dot a11y pattern). Rebuild Tailwind after adding classes (the v4 watcher can go stale).

---

## 9. Phased rollout (each phase shippable)

| Phase | Deliverable | Visible result |
|---|---|---|
| **0 — Foundation** | Migrations (§3), enums + model methods + broadcasts (§4), backfill `board_state`/`position`. | No UI change; data ready. |
| **1 — Board (manual)** | `board#show`, table + Kanban toggle, status groups, drag reorder, add item with type, status override, Session link. | Usable board, no agents. |
| **2 — Plan & PR columns** | Plan modal + edit, PR diff modal, `pr_*`/`pr_diff` storage. | Full board surface. |
| **3 — Manual agent pickup** | `/board-plan`, `/board-engineer`, `/board-debug`, `/board-answer` authored + registered; agent API contract (`tasks#update`, `tasks/:id/finish`); "Pick up" button. | One item, human-triggered, end-to-end. |
| **4 — Auto test-on-finish** | Test-plan/run creation, Playwright + relay legs, green→PR→in_review, red→failed (§6). | Items self-test and open PRs. |
| **5 — Review agent** | `/board-review` + per-project `AgentSchedule` (morning), dedupe into `pending`. | Backlog fills itself daily. |
| **6 — Full autopilot** | `AutopilotOrchestrator` + tick endpoint, one-at-a-time, daily cap, pause + global kill switch, per-project enable; daemon tick wiring. | Hands-off pipeline. |
| **7 — Polish** | Live broadcasts, a11y labels, empty states, responsive, minitest coverage for new models/controllers/jobs. | Production-ready. |

Phases 1–2 deliver immediate value on their own; agents come online incrementally so each step is verifiable before the next.

---

## 10. Risks / open items

- **Daemon change** — `myjira_session_launcher.py` (external, on host) must add the `autopilot/tick` POST. Launches themselves already work via the existing poll.
- **`gh` credentials in-container** — avoided: agents run on the host CLI and push `pr_url` + `pr_diff` back via API; the modal renders stored data.
- **Legacy `status` vs new `board_state`** — reconcile via data migration; keep `propagate_status_to_tasks` working.
- **Branch conflicts** — minimal under one-at-a-time per project.
- **Concurrency** — orchestrator guards against double-launch (in-flight check + advisory lock).
- **Tailwind v4** — rebuild after adding classes; watcher can die in the container.
- **Failed-item loop** — cap retries (e.g., 2) before parking a `failed` item for human review, so autopilot can't burn the daily cap on one broken item.
