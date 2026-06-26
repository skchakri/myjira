# Approve / Reject on the PR changes modal + comment log

**Date:** 2026-06-26
**Status:** Approved (design)

## Problem

When a board item reaches `in_review`, the only review affordance is a single
`✓` ("Approve & merge") button in the board **row**. The PR **changes modal**
(opened via the `#PR` pill) shows the diff but offers no way to act on it — no
approve, no reject. There is also no way to leave a note on an item explaining
*why* it is being moved (e.g. "merge conflicts, sending back to pending").

## Goal

1. Add **Approve** and **Reject** actions to the PR changes modal.
   - **Approve** → merge the PR to `main`, item → **Done**.
   - **Reject** → item → **Failed**, PR left **open** on GitHub.
2. Add an append-only **comment log** to each item so the user (and agents) can
   leave dated notes — and a status control on the task page so a Failed item
   can be commented and moved back to **Pending** in one place.

## Decisions (from brainstorming)

- **Reject leaves the PR open** on GitHub (item goes Failed locally only). No
  daemon / `gh` change required.
- **Comments are an append-only log** (new `TaskComment` model), not a single
  overwritten notes field — preserves history and lets agents post too.
- **A reason/comment is optional** on both Reject and move-to-Pending.

## Behavior

### Approve
Reuses the existing merge flow unchanged — it just becomes reachable from the
modal as well as the row:

1. Sets `merge_requested_at` (`Task#request_merge!`), guarded to
   `board_state == "in_review" && pr_url.present?`.
2. The host daemon (`myjira-session-launcher.service`) polls `board/pr_sync`,
   runs `gh pr merge`, and POSTs the result; `Board::PrSync` flips the item to
   **Done** on a confirmed merge.
3. While `merge_requested?` is true the UI shows a "Merging…" pulse instead of
   the buttons (prevents double submit).

### Reject
Purely local, no GitHub side effect:

1. `Task#reject_pr!(note: nil)` → `board_state = "failed"`.
2. `pr_url` / `pr_state` / `branch_name` are **left untouched** (PR stays open).
3. Does **not** increment `autopilot_attempts` (so re-queuing to Pending lets
   autopilot pick it up again — unlike `mark_failed!`, which bumps attempts).
4. If a reason is supplied it is appended as a comment: `"Rejected: <reason>"`.
5. Guarded to `board_state == "in_review" && pr_url.present?`.

### Comments
- Append-only. Each comment: `author` (default `"you"`; agents pass a role),
  `body`, `created_at`.
- Optional everywhere. Posting a comment never changes state on its own.

## Data model

New table `task_comments` (mirrors the `follow_up_tasks` shape):

| column      | type     | notes                         |
|-------------|----------|-------------------------------|
| id          | uuid     | PK, `gen_random_uuid()`       |
| task_id     | uuid     | FK → tasks, indexed, not null |
| author      | string   | default `"you"`, not null     |
| body        | text     | not null                      |
| created_at  | datetime | not null                      |
| updated_at  | datetime | not null                      |

- `TaskComment belongs_to :task`; `validates :body, presence: true`.
- `Task has_many :comments, class_name: "TaskComment", dependent: :destroy`,
  default order `created_at: :asc`.

## Controller / routes

Under the existing `resources :projects` board block (next to
`board/items/:id/merge`):

```ruby
post "board/items/:id/reject",   to: "boards#reject_pr",   as: :board_item_reject
post "board/items/:id/comments", to: "boards#add_comment", as: :board_item_comments
```

- `BoardsController#reject_pr` — calls `@task.reject_pr!(note: params[:reason])`,
  `refresh_board!`, redirect with notice; on guard failure, redirect with alert.
- `BoardsController#add_comment` — creates a `TaskComment` from
  `params[:comment][:body]` (author `"you"`), redirects back to the task page.
- `set_task` before_action extended to cover `:reject_pr` and `:add_comment`.

### API (for board agents)

```ruby
resources :tasks, only: [...] do
  resources :comments, only: [:index, :create]   # nested under tasks
end
```

`Api::V1::CommentsController#create` — `author` from payload (e.g. role name),
`body` required; returns the comment JSON. Lets `board-engineer` / `board-debug`
post progress or conflict notes that show in the same log.

## Views

- **`app/views/boards/_pr_modal.html.erb`** — footer action bar shown when
  `task.board_state == "in_review" && task.pr?`:
  - `✓ Approve & merge` → `button_to board_item_merge_path` (green, `pass` tokens),
    with `turbo_confirm`.
  - `✕ Reject` (red, `fail` tokens) → a small form with an optional reason
    `text_field` posting to `board_item_reject_path`.
  - If `task.merge_requested?` → "Merging…" pulse instead.
  - Keep the existing "Open on GitHub ↗" link.
- **`app/views/boards/_item.html.erb`** — in the action cell, add `✕` Reject next
  to the existing `✓` for `in_review` items (parity with the modal).
- **`app/views/tasks/show.html.erb`**:
  - New **Comments** card: list (`author · time` + `body`) + an "add a comment"
    form posting to `board_item_comments_path`.
  - A compact **status `<select>`** in the header (same inline auto-submit
    pattern as the board row) so the item can be moved (e.g. → Pending) from the
    task page. Reuses the existing `boards#update_item` PATCH endpoint.

## Testing (Minitest — custom stub helper, no mocha/webmock)

- **Model**: `reject_pr!` sets `failed`, leaves `pr_url`, does not bump
  `autopilot_attempts`; guard returns false when not `in_review`/no PR.
  `TaskComment` requires `body`; `Rejected:` comment is created when a reason is
  passed.
- **Controller**: `reject_pr` moves item to failed + redirects; `add_comment`
  creates a comment; `request_merge` still works from the modal path; reject
  guard path renders the alert.

## Lint

`bin/rubocop` after implementation; fix all offences.

## Out of scope

- Closing / re-opening the PR on GitHub from Reject (decided: leave open).
- A merge-conflict auto-detector. The user resolves conflicts manually and uses
  the comment + move-to-Pending flow.
