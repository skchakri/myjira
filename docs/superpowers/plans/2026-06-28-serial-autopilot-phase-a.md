# Strict Serial Autopilot + Reaper (Phase A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the board autopilot strictly one-item-at-a-time per project (state-based), with a daemon leg that returns dead-session items to the queue so it can never wedge.

**Architecture:** Replace the orchestrator's 8-minute-activity busy check with a state-based guard (`Project#board_busy?` = has an `in_progress` item). Add `Board::SessionSync` + a `board/session_sync` GET/POST pair (mirroring `Board::PrSync`) that the host daemon drives: it checks whether each in-flight item's tmux window still exists and demotes the ones whose window is gone back to `pending`. `waiting` items are already non-actionable, so they stay put and are skipped.

**Tech Stack:** Rails 8.1, Minitest (custom stub helper — no webmock/mocha), the host Python daemon `~/.claude/bin/myjira_session_launcher.py`.

This is Phase A of the spec `docs/superpowers/specs/2026-06-28-serial-autopilot-watchable-sessions-design.md`. Phases B (ttyd watch/resume) and C (per-session cost) are separate plans.

---

## File Structure

- `app/models/task.rb` — add `scope :in_progress`.
- `app/models/project.rb` — add `#board_busy?`.
- `app/services/autopilot/orchestrator.rb` — gate `tick_project` on `board_busy?`; raise the global ceiling so per-project serialization is the real limit.
- `app/services/board/session_sync.rb` — **new** service: `work` + `apply!`.
- `app/controllers/api/v1/board_controller.rb` — add `session_sync` / `session_sync_apply`.
- `config/routes.rb` — add the two `board/session_sync` routes under `api/v1`.
- `~/.claude/bin/myjira_session_launcher.py` — **new** `reconcile_board_sessions()` leg on the heartbeat (host file; runbook task, manual verify + service restart).
- Tests: `test/models/task_test.rb`, `test/models/project_test.rb`, `test/services/autopilot/orchestrator_test.rb` (new), `test/integration/board_session_sync_test.rb` (new).

---

### Task 1: `Task.in_progress` scope

**Files:**
- Modify: `app/models/task.rb` (near the other scopes, ~line 84)
- Test: `test/models/task_test.rb`

- [ ] **Step 1: Write the failing test**

Add to `test/models/task_test.rb` (inside `class TaskTest`):

```ruby
test "in_progress scope returns only in_progress items" do
  wip  = @project.tasks.create!(title: "WIP",  item_type: "task", board_state: "in_progress")
  @project.tasks.create!(title: "Pend", item_type: "task", board_state: "pending")
  @project.tasks.create!(title: "Wait", item_type: "task", board_state: "waiting")
  assert_equal [wip.id], @project.tasks.in_progress.pluck(:id)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/task_test.rb -n "/in_progress scope/"`
Expected: FAIL — `NoMethodError: undefined method 'in_progress'`.

- [ ] **Step 3: Add the scope**

In `app/models/task.rb`, directly below `scope :actionable, ...` (~line 84):

```ruby
  scope :in_progress, -> { where(board_state: "in_progress") }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/task_test.rb -n "/in_progress scope/"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/models/task.rb test/models/task_test.rb
git commit -m "Add Task.in_progress scope"
```

---

### Task 2: `Project#board_busy?`

**Files:**
- Modify: `app/models/project.rb` (next to `#inflight_board_launch?`)
- Test: `test/models/project_test.rb`

- [ ] **Step 1: Write the failing test**

Add to `test/models/project_test.rb` (create the file if missing with the skeleton below):

```ruby
require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "P", slug: "p-#{SecureRandom.hex(3)}", repo_path: "/tmp/p")
  end

  test "board_busy? is true only when an in_progress item exists" do
    assert_not @project.board_busy?, "no items → not busy"
    item = @project.tasks.create!(title: "Pend", item_type: "task", board_state: "pending")
    assert_not @project.board_busy?, "a pending item is not in progress"
    item.update!(board_state: "in_progress")
    assert @project.board_busy?, "an in_progress item makes the project busy"
    item.update!(board_state: "in_review")
    assert_not @project.board_busy?, "leaving in_progress frees the project"
  end

  test "a waiting item does not make the project busy" do
    @project.tasks.create!(title: "Wait", item_type: "task", board_state: "waiting")
    assert_not @project.board_busy?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/project_test.rb -n "/board_busy/"`
Expected: FAIL — `NoMethodError: undefined method 'board_busy?'`.

- [ ] **Step 3: Add the method**

In `app/models/project.rb`, immediately after `def inflight_board_launch?` / its `end`:

```ruby
  # State-based one-item-at-a-time guard: the autopilot picks the next item only
  # when this is false. A dead session's item is returned to the queue by the
  # daemon's session-sync leg (Board::SessionSync), so this can't wedge.
  def board_busy?
    tasks.in_progress.exists?
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/project_test.rb -n "/board_busy|waiting item/"`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add app/models/project.rb test/models/project_test.rb
git commit -m "Add Project#board_busy? state-based pipeline guard"
```

---

### Task 3: Orchestrator gates on `board_busy?` (strict serial)

**Files:**
- Modify: `app/services/autopilot/orchestrator.rb` (`tick_project`, and `GLOBAL_MAX_CONCURRENT`)
- Test: `test/services/autopilot/orchestrator_test.rb` (new)

- [ ] **Step 1: Write the failing tests**

Create `test/services/autopilot/orchestrator_test.rb`:

```ruby
require "test_helper"

class AutopilotOrchestratorTest < ActiveSupport::TestCase
  setup do
    Setting.where(key: "autopilot_stopped").destroy_all
    @project = Project.create!(name: "AP", slug: "ap-#{SecureRandom.hex(3)}", repo_path: "/tmp/ap",
                               autopilot_enabled: true, autopilot_paused: false,
                               autopilot_review_enabled: false)
  end

  test "tick_project skips a project that already has an in_progress item" do
    @project.tasks.create!(title: "Running", item_type: "task", board_state: "in_progress")
    @project.tasks.create!(title: "Next", item_type: "task", board_state: "pending")
    assert_no_difference -> { @project.session_launches.count } do
      Autopilot::Orchestrator.tick_project(@project)
    end
  end

  test "tick_project advances exactly one item when the project is free" do
    @project.tasks.create!(title: "Next", item_type: "task", board_state: "pending")
    assert_difference -> { @project.session_launches.where.not(pipeline_step: nil).count }, 1 do
      Autopilot::Orchestrator.tick_project(@project)
    end
  end

  test "a waiting item neither blocks nor is picked up" do
    @project.tasks.create!(title: "Wait", item_type: "task", board_state: "waiting")
    assert_no_difference -> { @project.session_launches.count } do
      Autopilot::Orchestrator.tick_project(@project)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/services/autopilot/orchestrator_test.rb`
Expected: FAIL — the "skips ... in_progress" test fails because the current guard (`inflight_board_launch?`) ignores `in_progress` items with no recent session activity, so it launches a second one.

- [ ] **Step 3: Change the guard**

In `app/services/autopilot/orchestrator.rb`, in `tick_project`, replace:

```ruby
        next if project.inflight_board_launch?
```

with:

```ruby
        next if project.board_busy?
```

Then raise the global ceiling so per-project serialization is the real limit. Change:

```ruby
    GLOBAL_MAX_CONCURRENT = ENV.fetch("MYJIRA_AUTOPILOT_MAX_CONCURRENT", "3").to_i
```

to:

```ruby
    # With strict per-project serialization (Project#board_busy?) the meaningful
    # limit is one session per project; this is only a fleet-wide safety ceiling.
    GLOBAL_MAX_CONCURRENT = ENV.fetch("MYJIRA_AUTOPILOT_MAX_CONCURRENT", "20").to_i
```

(Leave `run_once` using `inflight_board_launch?`-free path as is; it already calls `advance_project` directly without the busy guard — verify it still reads sensibly, no change required.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/services/autopilot/orchestrator_test.rb`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add app/services/autopilot/orchestrator.rb test/services/autopilot/orchestrator_test.rb
git commit -m "Autopilot: strict one-in_progress-per-project serial guard"
```

---

### Task 4: `Board::SessionSync` service

**Files:**
- Create: `app/services/board/session_sync.rb`
- Test: `test/integration/board_session_sync_test.rb` (model-level tests live here too)

- [ ] **Step 1: Write the failing test**

Create `test/integration/board_session_sync_test.rb`:

```ruby
require "test_helper"

class BoardSessionSyncTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "SS", slug: "ss-#{SecureRandom.hex(3)}", repo_path: "/tmp/ss")
  end

  def in_progress_with_launch(target: "myjira:ss-abc", launched_at: 10.minutes.ago)
    task = @project.tasks.create!(title: "WIP", item_type: "task", board_state: "in_progress")
    @project.session_launches.create!(prompt: "/board-engineer", status: "launched",
                                      repo_path: "/tmp/ss", session_id: SecureRandom.uuid,
                                      pipeline_step: "engineering",
                                      tmux_target: target, launched_at: launched_at, task: task)
    task
  end

  test "work lists in_progress items with a launched tmux target past the spawn grace" do
    task = in_progress_with_launch
    rows = Board::SessionSync.work
    assert_equal [task.id], rows.map { |r| r[:task_id] }
    assert_equal "myjira:ss-abc", rows.first[:tmux_target]
  end

  test "work skips a launch still inside the spawn grace" do
    in_progress_with_launch(launched_at: 5.seconds.ago)
    assert_empty Board::SessionSync.work
  end

  test "apply! with alive:false demotes the in_progress item back to pending" do
    task = in_progress_with_launch
    assert_equal "requeued", Board::SessionSync.apply!(task, alive: false)
    task.reload
    assert_equal "pending", task.board_state
    assert_equal 1, task.autopilot_attempts
    assert_match(/re-queued/i, task.agent_notes)
  end

  test "apply! with alive:true is a no-op" do
    task = in_progress_with_launch
    assert_equal "alive", Board::SessionSync.apply!(task, alive: true)
    assert_equal "in_progress", task.reload.board_state
  end

  test "apply! never demotes an item that already left in_progress" do
    task = in_progress_with_launch
    task.update!(board_state: "in_review")
    assert_equal "not_in_progress", Board::SessionSync.apply!(task, alive: false)
    assert_equal "in_review", task.reload.board_state
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/board_session_sync_test.rb`
Expected: FAIL — `NameError: uninitialized constant Board::SessionSync`.

- [ ] **Step 3: Create the service**

Create `app/services/board/session_sync.rb`:

```ruby
# Reconciles in_progress board items with their Claude CLI tmux session. The Rails
# container can't see host tmux, so the host daemon does the check: it GETs #work,
# runs `tmux has-session` / `list-windows` per item, and POSTs which windows are
# still alive. #apply! returns a dead session's item to the queue so the autopilot
# (Project#board_busy?) can pick the next one — the self-healing half of the
# strict-serial guard. Mirrors Board::PrSync.
module Board
  module SessionSync
    module_function

    # Don't reap a launch whose tmux window may still be mid-spawn.
    SPAWN_GRACE = 90.seconds

    # The daemon's check-list: in_progress items whose latest board launch is
    # "launched" with a tmux target, past the spawn grace.
    def work
      Task.in_progress.includes(:project).filter_map do |task|
        launch = task.session_launches.where.not(pipeline_step: nil)
                     .where(status: "launched").where.not(tmux_target: [nil, ""])
                     .order(launched_at: :desc).first
        next unless launch
        next if launch.launched_at && launch.launched_at > SPAWN_GRACE.ago
        { task_id: task.id, launch_id: launch.id, slug: task.project.slug,
          tmux_target: launch.tmux_target }
      end
    end

    # Apply one daemon-reported liveness outcome.
    #   alive:true  → still running, leave it.
    #   alive:false → window gone; if the agent never moved it out of in_progress,
    #                 return it to the queue (bump attempts, note).
    def apply!(task, alive:)
      return "alive" if alive
      return "not_in_progress" unless task.board_state == "in_progress"

      task.update!(board_state: "pending",
                   autopilot_attempts: task.autopilot_attempts + 1,
                   agent_notes: "Session ended without reporting a result; re-queued.")
      "requeued"
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/board_session_sync_test.rb`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add app/services/board/session_sync.rb test/integration/board_session_sync_test.rb
git commit -m "Add Board::SessionSync: requeue items whose CLI session died"
```

---

### Task 5: `board/session_sync` GET/POST endpoints

**Files:**
- Modify: `config/routes.rb` (api/v1 board block, next to `pr_sync`)
- Modify: `app/controllers/api/v1/board_controller.rb`
- Test: `test/integration/board_session_sync_test.rb` (append endpoint tests)

- [ ] **Step 1: Write the failing endpoint tests**

Append to `test/integration/board_session_sync_test.rb` (inside the class):

```ruby
  test "GET session_sync returns the daemon check-list" do
    task = in_progress_with_launch
    get "/api/v1/board/session_sync"
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [task.id], body["to_check"].map { |h| h["task_id"] }
  end

  test "POST session_sync applies liveness outcomes" do
    task = in_progress_with_launch
    post "/api/v1/board/session_sync",
         params: { results: [{ task_id: task.id, alive: false }] }, as: :json
    assert_response :success
    assert_equal "pending", task.reload.board_state
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/integration/board_session_sync_test.rb -n "/session_sync (returns|applies)/"`
Expected: FAIL — routing error (no `board/session_sync` route).

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, in the `namespace :api { namespace :v1 { ... } }` block, directly after the two `board/pr_sync` lines:

```ruby
      # Host-side daemon: reconcile in_progress items with their CLI tmux session.
      # GET = which items to check; POST = apply `tmux has-session` liveness.
      get  "board/session_sync", to: "board#session_sync"
      post "board/session_sync", to: "board#session_sync_apply"
```

- [ ] **Step 4: Add the controller actions**

In `app/controllers/api/v1/board_controller.rb`, add inside the class (next to `pr_sync` / `pr_sync_apply`, above the `private` section):

```ruby
      def session_sync
        render json: { to_check: Board::SessionSync.work }
      end

      def session_sync_apply
        applied = Array(params[:results]).filter_map do |r|
          task = Task.find_by(id: r[:task_id])
          next unless task

          { task_id: task.id, result: Board::SessionSync.apply!(task, alive: to_bool(r[:alive])) }
        end
        render json: { applied: applied }
      end
```

(The `to_bool` private helper already exists in this controller — used by `pr_sync_apply`.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/integration/board_session_sync_test.rb`
Expected: PASS (7 tests total).

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/controllers/api/v1/board_controller.rb test/integration/board_session_sync_test.rb
git commit -m "Add board/session_sync GET/POST for the daemon session reaper"
```

---

### Task 6: Full suite green

**Files:** none (verification gate).

- [ ] **Step 1: Build the Tailwind asset (integration tests render the layout)**

Run: `bin/rails tailwindcss:build`
Expected: `Done in NNNms`.

- [ ] **Step 2: Run the full suite**

Run: `bin/rails test`
Expected: PASS — 0 failures, 0 errors. (If you see `Missing Active Record encryption credential`, copy `config/master.key` from the main checkout into this worktree first; if you see `tailwind.css was not found`, re-run Step 1.)

- [ ] **Step 3: Lint**

Run: `bin/rubocop app/models/task.rb app/models/project.rb app/services/autopilot/orchestrator.rb app/services/board/session_sync.rb app/controllers/api/v1/board_controller.rb`
Expected: `no offenses detected`.

---

### Task 7: Daemon session-reaper leg (host file — runbook)

**Files:**
- Modify: `~/.claude/bin/myjira_session_launcher.py` (not in the repo; host-side)

This task is host infrastructure — no Rails test. Implement, then verify manually.

- [ ] **Step 1: Add the reconcile function**

In `~/.claude/bin/myjira_session_launcher.py`, after `def reconcile_board_prs():`, add:

```python
def reconcile_board_sessions():
    """Requeue in_progress board items whose Claude CLI tmux window has died.
    myjira hands us the check-list (GET) and applies the board moves (POST); we
    just report `tmux has-session` / window-existence per item. The self-healing
    half of the strict one-at-a-time guard."""
    try:
        work = (_request("GET", "/api/v1/board/session_sync") or {}).get("to_check", [])
    except Exception as e:
        log(f"session_sync poll failed: {e}")
        return
    if not work:
        return
    results = []
    for it in work:
        target = it["tmux_target"]                       # e.g. "myjira:ss-abc"
        sess, _, win = target.partition(":")
        alive = subprocess.run(["tmux", "has-session", "-t", sess],
                               capture_output=True).returncode == 0
        if alive and win:
            out = subprocess.run(["tmux", "list-windows", "-t", sess, "-F", "#{window_name}"],
                                 capture_output=True, text=True).stdout.split()
            alive = win in out
        results.append({"task_id": it["task_id"], "alive": alive})
        if not alive:
            log(f"session reaped: {it['slug']} task {it['task_id']} (window {target} gone)")
    try:
        _request("POST", "/api/v1/board/session_sync", {"results": results})
    except Exception as e:
        log(f"session_sync apply failed: {e}")
```

- [ ] **Step 2: Call it on the heartbeat**

In `main()`, where the tick block calls `reconcile_board_prs()`, add the new call right after it:

```python
            tick_schedules()
            reconcile_board_prs()
            reconcile_board_sessions()
            last_tick = now
```

- [ ] **Step 3: Restart the daemon (it runs on-disk code)**

Run: `systemctl --user restart myjira-session-launcher.service`
Then: `systemctl --user status myjira-session-launcher.service` → Expected: `active (running)`.

- [ ] **Step 4: Manual verification**

1. Confirm a healthy in_progress item with a live tmux window is NOT demoted across a tick (watch `journalctl --user -u myjira-session-launcher.service -f` — no "session reaped" for it).
2. Kill a board session's tmux window (`tmux kill-window -t <target>`); within ~1 tick the log shows `session reaped: …` and the item returns to `pending` on the board.

---

### Task 8: One-time cleanup (runbook — not committed code)

**Files:** none (operational).

- [ ] **Step 1: Reset the stuck in_progress orphans to pending**

Run:
```bash
docker exec pyr-myjira bin/rails runner '
n = Task.where(board_state: "in_progress").update_all(board_state: "pending")
puts "reset #{n} stuck in_progress items to pending"'
```
Expected: prints the count (~16). The strict-serial flow re-picks them one at a time.

- [ ] **Step 2: List the stashes for review (do not drop)**

Run: `cd /home/kalyan/platform/skchakri/myjira && git stash list`
Expected: the ~16 stashes printed. Leave them; report the list to the user.

---

## Notes

- **No double-launch:** `tick_project` stays inside `project.with_lock`.
- **Deadlock impossibility:** if a session dies, Task 7's leg demotes its item, clearing `board_busy?` so the project resumes — the state guard cannot wedge.
- **`waiting`:** unchanged — already excluded from `actionable` and from `in_progress`, so it neither blocks nor is re-picked (covered by tests in Tasks 2 & 3).
- Phase B (ttyd watch/resume) and Phase C (per-session cost) follow as separate plans once this merges.
