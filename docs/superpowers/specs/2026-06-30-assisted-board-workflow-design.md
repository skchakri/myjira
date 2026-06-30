# Assisted Board Workflow — Design Spec

**Date:** 2026-06-30
**Status:** Approved (design); pending implementation plan
**Owner:** skchakri (solo user)

## Summary

Turn the autonomous board autopilot into a **human-in-the-loop "assisted" workflow**.
Today the pipeline plans *and* executes on its own (auto-opens PRs). This change inserts
a **plan → approve → execute** gate on every board item, folds related pending items into
**one consolidated task**, and **notifies** the user (landing-page blink + true Web Push)
whenever an item needs input or approval. The user answers questions and approves/changes
the plan **in the browser**, then execution proceeds — and the live session remains
watchable at any time via the existing Conversations/worklog surfaces.

This is an enhancement of the existing board pipeline, not a rebuild: it reuses the
`waiting` board state, the `plan` field + plan modal, the `steer`/`continue_session`
resume mechanism, the `Autopilot::Orchestrator` + `Board::Pipeline`, the `InstantTriageJob`
(Haiku) on pending-create, and Turbo Streams as the real-time transport.

## Goals

- Every board item stops for **human approval** before any execution (no surprise PRs).
- New tasks/improvements **auto-merge** with related pending items into a single task.
- The user is **notified** when input or approval is needed — even with the tab closed.
- Answer questions, review the full plan, and **Approve / Request changes** in-browser.
- The running session is **watchable at any time** (already true; surface it prominently).
- Apply to **all projects** by default.

## Non-Goals (v1)

- Multi-user, auth, roles (myjira remains single-user, no-auth).
- Replacing Turbo Streams with bespoke ActionCable channels.
- AI-judged "auto-approve" of low-risk plans (everything is human-gated for now).
- A new board column/state — we reuse `waiting` + a `wait_reason` flag (see Decisions).

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Execution gate | **Gate everything** — every item parks for approval after planning |
| Consolidation | **Auto-merge** related pending items (reversible, not confirmation-prompted) |
| Notifications | **Landing-page blink** (Turbo) **+ true Web Push** (service worker + VAPID) |
| Scope | **All projects** by default |
| Architecture | **Approach A** (reuse `waiting` + `wait_reason`) **+ C** (cross-project `/approvals` inbox) |
| Push reach | **Even when the tab is closed** (service worker + VAPID) |
| `planned` semantics | `planned` now means **approved & queued for execution** |
| `ask` items | **Gated too** — approve the planned approach before `board-answer` runs |
| `in_review` order | **Immutable, finish-of-development order** — not reorderable; merged in that order |
| Execution boundary | **myjira tracks; the client project's CLI executes** — all work context comes from the project folder |

## Execution Boundary — myjira tracks, the project CLI executes

myjira is **only a tracker + relay**. Every board item is a **clear, self-contained
instruction** ("what needs to be done"); the actual planning, engineering, debugging, and
answering run as a **Claude CLI session inside the client project's own folder**
(cwd = `project.repo_path`, launched by the host daemon — already how `Board::Pipeline`
works). That session takes **all of its context from the project folder**: the code,
`CLAUDE.md`, `.claude/` config, and git history. myjira holds **no project code or
build context**.

Only three things cross back to myjira (over the API `base_url` the command is given):

1. **Status updates** — board_state transitions (`planned → waiting → in_progress → …`).
2. **Questions** — when the session needs input, it posts them to myjira
   (`pending_questions`); myjira notifies the user and collects answers.
3. **The plan** — posted for approval; myjira collects Approve / Request-changes.

Answers and approvals collected in myjira are **relayed back into the same project-folder
session** (resume via `resume_of_session_id`), where execution continues with full project
context. The browser is purely the human-input surface; nothing about the work itself lives
in myjira.

**Tracker-side vs project-side reasoning:** triage and consolidation operate on **myjira
item metadata** (titles/descriptions of pending items) and may run server-side (Haiku) — they
do not read project code. Anything that needs code-level understanding (planning, implementing,
debugging, answering) runs **only** in the project-folder session.

## Core State Model — `planned` means "approved"

The planner **stops setting `planned` directly**. Instead it parks the item in the existing
`waiting` state with a new `wait_reason`. `planned` is now reached **only after the user
approves**. Because the orchestrator already auto-executes `planned` items, the gate needs
essentially no new orchestrator logic — it is enforced by the planner never producing
`planned` itself.

```
pending ──plan──▶ waiting(needs_input) ──user answers──▶ (resume planner) ──▶ waiting(awaiting_approval)
   │                                                                                │
   └──────────────── plan, no questions ──────────────────────────────────────────▶│
                                                                                     │ Approve
   Request changes ◀─────────────────────────────────────────────────────────────  │
        │ (re-plan, plan_version++)                                                  ▼
        └──────────────────────────────▶ waiting(awaiting_approval)            planned ─▶ in_progress ─▶ in_review ─▶ done
```

Lifecycle rules:
- A planner run sets `waiting` + `wait_reason = needs_input` (it has questions) **or**
  `wait_reason = awaiting_approval` (plan is ready).
- `failed → planning` re-plans, then parks in `waiting:awaiting_approval` like any other plan.
- Approve: `waiting:awaiting_approval → planned`, `wait_reason` cleared; the next orchestrator
  tick (or an immediate triggered tick) advances `planned → in_progress` and executes.
- Request changes: re-plan with the user's notes, bump `plan_version`, return to
  `waiting:awaiting_approval`.
- `waiting` is **not** in `ACTIONABLE_STATES`, so the orchestrator already skips parked items —
  no auto-advance is possible while awaiting the human.

## `in_review` Ordering — Immutable, Finish-of-Development Order

The `in_review` queue must always reflect **the order items finished development**, so the
merge sequence matches the real completion sequence. The order is **not user-reorderable**.

- **Stable timestamp:** add `review_ready_at`, stamped exactly once in `Task#mark_in_review!`
  (when development finishes / the PR opens) and never changed afterward. (Existing
  `updated_at` is unsuitable — it moves on any edit; `finished_at` is set only at `done`.)
- **Ordering everywhere:** the cross-project `/review` page, the board's `in_review` group,
  and the `/approvals` inbox all order `in_review` items by `review_ready_at ASC`
  (oldest-finished first). Replaces the current `updated_at DESC` ordering in
  `reviews_controller#index`.
- **Reorder locked:** the `in_review` group is **not draggable** in the UI, and
  `boards_controller#reorder` rejects/ignores any id whose `board_state = in_review`
  (server-side guard — `position` is meaningless for review items).
- **Merge in order:** the host daemon's `pr_sync` merge train processes
  approved-for-merge items by `review_ready_at ASC`, so commits land in finish-of-dev order.

## Data Model Changes

New columns on `tasks`:

| Column | Type | Meaning |
|---|---|---|
| `wait_reason` | string, nullable | `needs_input` \| `awaiting_approval`; set while `board_state = waiting`, cleared on leaving |
| `pending_questions` | jsonb, default `[]` | `[{ "id": "q1", "q": "…", "a": null }]` — agent questions + the user's answers |
| `merged_into_id` | uuid, nullable | set on a secondary that was folded into a primary during consolidation |
| `plan_version` | integer, default `1` | bumped on each re-plan after "Request changes"; UI shows "revised" |
| `review_ready_at` | datetime, nullable | stamped once in `mark_in_review!`; the immutable finish-of-development order key |

New table `push_subscriptions` (one row per browser/device):

| Column | Type |
|---|---|
| `endpoint` | string (unique) |
| `p256dh` | string |
| `auth` | string |
| `user_agent` | string, nullable |
| timestamps | |

Board queue excludes consolidated items: `where(merged_into_id: nil)`.

## Components

### `Board::Consolidator` (auto-merge)
- Triggered from the existing `InstantTriageJob` (fires Haiku on every pending-create).
- After triage classifies the new item, shortlist other **`pending`** items in the same
  project via a cheap pre-filter (`search_vector` similarity / `Project#open_board_duplicate`
  fingerprint), then ask Haiku which represent the same/overlapping work.
- Merge: choose a primary (oldest pending, to preserve board position/history); append each
  secondary's title + description under a `## Merged sub-items` section of the primary;
  set each secondary's `merged_into_id`; broadcast a board refresh.
- **Safety:** only `pending` items are ever merged (never planned/in-flight); each merge is
  written to the worklog; an **Unmerge** action restores a secondary to `pending`
  (`merged_into_id = null`). Auto, but reversible and auditable.

### Q&A → Approve/Change (inline on the task page)
- **needs_input:** the task page renders a "The agent needs your input" panel — one answer
  box per `pending_questions` entry. Submitting (`POST /board/items/:id/answer_questions`)
  stores answers and **resumes the planning session** via the existing
  `resume_of_session_id` / `continue_session` path, instructing it to finalize and park in
  `awaiting_approval`.
- **awaiting_approval:** the full plan renders inline (existing plan-modal markdown) with:
  - **Approve** → `POST /board/items/:id/approve` → `planned`, clear `wait_reason`, fire an
    immediate orchestrator tick so execution starts promptly.
  - **Request changes** → `POST /board/items/:id/request_changes` → either an inline plan
    editor (save your own edits, stay in `awaiting_approval`) **or** a notes box that re-runs
    the planner with the feedback, bumps `plan_version`, and returns to `awaiting_approval`.

### `/approvals` cross-project inbox (Approach C)
- New `ApprovalsController#index` + `get "approvals"`, modeled on the existing
  `reviews_controller`/`/review` page. Lists every `waiting` item across all projects,
  grouped by project, split into **Needs your input** (`needs_input`) and **Awaiting
  approval** (`awaiting_approval`), each with its Q&A box / plan + Approve / Change inline.
- Added to the nav next to **Review**. This is the deep-link target for the blink and push.

### Notifications
1. **Landing-page blink** (`projects/index`):
   - Extract a `projects/_card` partial; add a Turbo subscription to the index.
   - Each card shows a "needs you" badge + pulse driven by `Project#needs_attention?`
     (any `waiting` item with a `wait_reason`).
   - When an item enters/leaves `waiting`, re-broadcast the card partial → it pulses live.
2. **True Web Push** (service worker + VAPID):
   - Add the `web-push` gem; generate VAPID keys (stored in Rails credentials / `.env`).
   - `PushSubscription` model + `push_subscriptions` register/unregister endpoints.
   - `public/sw.js` service worker (served at root scope) + a layout Stimulus controller
     that registers the SW, requests `Notification` permission, subscribes to `PushManager`,
     and posts the subscription to the server.
   - `WebPush::Notifier` fires when an item enters `waiting` (either reason) → desktop
     notification with a `data.url` deep-link to the task (or `/approvals`); the SW
     `notificationclick` opens/focuses that URL.
   - Centralized chokepoint: `Task#notify_waiting!`, called from the state setters when
     `board_state → waiting` with a `wait_reason`.

### "See the session anytime"
- Already covered by Conversations + the worklog timeline + the item's live session link.
  The push and inbox both deep-link to the task page, which embeds the live
  conversation/worklog. Minimal change: surface the live-session link prominently while
  `in_progress`.

## Data Flow

**New item → consolidation → plan → gate:**
pending create → `InstantTriageJob` (Haiku triage) → `Board::Consolidator` folds related
pending items → orchestrator tick → `board-plan` runs → parks in `waiting:needs_input`
(if questions) or `waiting:awaiting_approval` → `Task#notify_waiting!` (blink + push).

**Answer → finalize:**
user answers on task page / `/approvals` → answers stored → planning session resumed →
planner finalizes → `waiting:awaiting_approval` → notify.

**Approve → execute:**
Approve → `planned` (approved) → immediate tick → `Board::Pipeline` launches
engineering/debugger/answer → `in_progress` → `in_review` (PR) → `done`. (For `ask` items:
`board-answer` writes the answer, no PR, → `done`.)

## Command Contract Changes (external `~/.claude/commands`, documented in `docs/board/PLAN.md`)

- **board-plan:** instead of setting `planned`, set `waiting` + `wait_reason`. When it has
  open questions, write them to `pending_questions` and use `needs_input`; otherwise write
  the plan and use `awaiting_approval`. On resume (answers present) it finalizes to
  `awaiting_approval`.
- **board-review / board-triage:** after dedup detection, call the consolidation path so
  related pending items are merged into one.
- **board-engineer / board-debug / board-answer:** unchanged — they only ever run on
  `planned` (now = approved) items.

## Error Handling

- Planner crash/timeout → existing `failed` path (re-plan applies); never silently stuck.
- Web Push send failure → log and continue; prune subscriptions returning HTTP 410 (Gone);
  push is best-effort — blink + `/approvals` are the reliable surfaces.
- False merge → reversible via **Unmerge**; every merge logged to the worklog.
- Notification permission denied → app fully functional; a one-time banner offers to enable.
- Concurrency → all transitions use the existing `with_lock`; consolidation is guarded to
  `pending`-only under lock; the existing `Project#board_busy?` keeps execution serial.

## Testing (Minitest + the repo's custom stub helper — no webmock/mocha)

- **Model:** `wait_reason` transitions; `planned` = approved (orchestrator-executable);
  `merged_into_id` excluded from the board queue; `Project#needs_attention?`.
- **Service:** `Board::Consolidator` merges `pending`-only, appends descriptions, sets
  `merged_into_id`, is reversible, and skips non-pending; `WebPush::Notifier` sends to all
  subscriptions and prunes 410 (web-push send stubbed).
- **Orchestrator:** never advances a `waiting` item; advances approved `planned` to
  engineering.
- **Controllers:** `approve` (waiting→planned + tick), `answer_questions` (stores + resumes),
  `request_changes` (re-plan + version bump), `merge`/`unmerge`.
- **Approvals inbox:** groups by project and splits `needs_input` vs `awaiting_approval`.
- **`in_review` ordering:** `review_ready_at` stamped once and immutable; `/review` and the
  in_review group order by it ASC; `reorder` refuses to move an `in_review` item.
- **Component:** the project card renders the blink/badge when `needs_attention?`.

## Phasing (shared data model first, then independent slices)

- **P1** — data model + gate + inline Approve/Change/Q&A on the task page.
- **P2** — `Board::Consolidator` auto-merge (+ Unmerge) wired into `InstantTriageJob`.
- **P3** — `/approvals` cross-project inbox + landing-page blink.
- **P4** — true Web Push (gem, VAPID, `PushSubscription`, `sw.js`, `WebPush::Notifier`).

## Files (high level)

- **Migrations:** add `wait_reason`, `pending_questions`, `merged_into_id`, `plan_version`
  to `tasks`; create `push_subscriptions`.
- **Models:** `task.rb` (transitions, `notify_waiting!`, scopes); `push_subscription.rb`;
  `project.rb` (`needs_attention?`, queue scope excluding merged).
- **Services:** `board/consolidator.rb`; `web_push/notifier.rb`; tweaks to
  `autopilot/orchestrator.rb` + `board/pipeline.rb` (planner parks in `waiting`).
- **Jobs:** `InstantTriageJob` calls the consolidator.
- **Controllers:** `boards_controller` (`approve`, `request_changes`, `answer_questions`,
  `merge`, `unmerge`); `approvals_controller`; `push_subscriptions_controller`.
- **Views:** `projects/index` + `projects/_card` (blink/badge + Turbo sub);
  `boards/_item` + `_kanban_card` + `_plan_modal` (waiting/approve/change UI + Q&A panel);
  `approvals/index`; layout (SW register + permission banner). `public/sw.js`.
- **Routes:** `approvals`; `board/items/:id/{approve,request_changes,answer_questions}`;
  `board/items/{merge,:id/unmerge}`; `push_subscriptions`.
- **Config:** `web-push` gem; VAPID keys in credentials/`.env`.
- **Docs/commands:** update `docs/board/PLAN.md` and the `board-plan`/`board-review`/
  `board-triage` command contracts.

## Open Questions / To Confirm During Planning

- Exact Haiku prompt + similarity threshold for `Board::Consolidator` (precision over recall
  to avoid false merges).
- Whether "Request changes" defaults to the inline editor or the re-plan-with-notes path
  (both ship; which is the primary button).
- VAPID key storage location (Rails credentials vs `.env`) and the dev/prod split.
