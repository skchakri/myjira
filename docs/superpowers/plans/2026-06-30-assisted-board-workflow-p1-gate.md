# Assisted Board Workflow — Phase 1: Approval Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop every board item at `waiting` after planning and require an in-browser Approve / Request-changes / answer-questions step before execution proceeds.

**Architecture:** Reuse the existing `waiting` board state with a new `wait_reason` flag (`needs_input` | `awaiting_approval`). The planner no longer produces `planned` directly — the API converts any agent-set `planned` into `waiting:awaiting_approval`, so the gate holds even if the external `board-plan` command is unchanged. `planned` is now reached **only** via the human Approve action, and the existing orchestrator already auto-executes `planned` items, so no orchestrator change is needed. Answers/change-requests resume the planning session in the project folder (existing `resume_of_session_id` path).

**Tech Stack:** Rails 8, PostgreSQL (jsonb), Hotwire/Turbo, Minitest (with the repo's custom `StubSupport` helper — no webmock/mocha).

**Scope of this phase:** the gate + Q&A + Approve/Change, on the task page. Out of scope (separate plans): `review_ready_at`/in_review ordering, `Board::Consolidator` auto-merge, the `/approvals` inbox + landing-page blink, and Web Push.

**Spec:** `docs/superpowers/specs/2026-06-30-assisted-board-workflow-design.md`

---

## File Structure

- **Migration** `db/migrate/*_add_approval_gate_to_tasks.rb` — `wait_reason`, `pending_questions`, `plan_version`.
- **Model** `app/models/task.rb` — constants, validation, predicates, and transition methods (`submit_plan!`, `ask_questions!`, `approve_plan!`, `record_answers!`, `request_changes!`); auto-clear `wait_reason` when leaving `waiting`.
- **API** `app/controllers/api/v1/tasks_controller.rb` — gate: convert incoming `planned` → `waiting:awaiting_approval`; permit `wait_reason`, `pending_questions`.
- **Routes** `config/routes.rb` — `approve`, `request_changes`, `answer_questions` under `board/items/:id`.
- **Controller** `app/controllers/boards_controller.rb` — the three actions above (resume reuses the existing `continue_session` pattern).
- **Views** `app/views/boards/_approval_panel.html.erb` (new) rendered from `app/views/tasks/show.html.erb`; a small badge on `app/views/boards/_item.html.erb`.
- **Docs** `docs/board/PLAN.md` — document the new planner contract.

---

## Task 1: Migration — approval-gate columns on `tasks`

**Files:**
- Create: `db/migrate/20260630000001_add_approval_gate_to_tasks.rb`

- [ ] **Step 1: Write the migration**

```ruby
class AddApprovalGateToTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :tasks, :wait_reason, :string
    add_column :tasks, :pending_questions, :jsonb, null: false, default: []
    add_column :tasks, :plan_version, :integer, null: false, default: 1
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: migration runs; `db/schema.rb` now shows `wait_reason`, `pending_questions`, `plan_version` on `tasks`.

- [ ] **Step 3: Commit**

```bash
git add db/migrate/20260630000001_add_approval_gate_to_tasks.rb db/schema.rb
git commit -m "feat(board): add approval-gate columns to tasks"
```

---

## Task 2: Model — `wait_reason` constant, validation, predicates, auto-clear

**Files:**
- Modify: `app/models/task.rb`
- Test: `test/models/task_test.rb`

- [ ] **Step 1: Write the failing test**

Add to `test/models/task_test.rb`:

```ruby
test "wait_reason must be a known value or blank" do
  item = @project.tasks.create!(title: "X", item_type: "task", board_state: "pending")
  item.update!(board_state: "waiting", wait_reason: "needs_input")
  assert item.needs_input?
  item.update!(wait_reason: "awaiting_approval")
  assert item.awaiting_approval?
  item.wait_reason = "bogus"
  assert_not item.valid?
end

test "leaving the waiting state clears wait_reason" do
  item = @project.tasks.create!(title: "X", item_type: "task",
                                board_state: "waiting", wait_reason: "awaiting_approval")
  item.update!(board_state: "planned")
  assert_nil item.reload.wait_reason
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/models/task_test.rb -n "/wait_reason|clears wait_reason/"`
Expected: FAIL (`needs_input?` undefined / wait_reason not cleared).

- [ ] **Step 3: Implement**

In `app/models/task.rb`, after the `AGENT_ROLES` constant (line ~20) add:

```ruby
  # Why an item sits in `waiting`: the agent posed questions (needs_input) or the
  # plan is ready and the human must Approve / Request changes (awaiting_approval).
  WAIT_REASONS = %w[needs_input awaiting_approval].freeze
```

After the `validates :agent_role …` line (line ~65) add:

```ruby
  validates :wait_reason, inclusion: { in: WAIT_REASONS }, allow_blank: true
```

Add a `before_save` near the other callbacks (after line ~106):

```ruby
  # `wait_reason` is only meaningful while parked in `waiting`; clear it on exit so
  # an approved/executing item never carries a stale reason.
  before_save :clear_wait_reason_off_waiting

```

With the predicates added near `actionable?` (line ~142):

```ruby
  def needs_input?
    board_state == "waiting" && wait_reason == "needs_input"
  end

  def awaiting_approval?
    board_state == "waiting" && wait_reason == "awaiting_approval"
  end
```

And the private callback (in the `private` section, after `assign_position`):

```ruby
  def clear_wait_reason_off_waiting
    self.wait_reason = nil if board_state != "waiting"
  end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/models/task_test.rb -n "/wait_reason|clears wait_reason/"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/models/task.rb test/models/task_test.rb
git commit -m "feat(board): wait_reason flag with validation, predicates, auto-clear"
```

---

## Task 3: Model — `submit_plan!` and `ask_questions!`

**Files:**
- Modify: `app/models/task.rb`
- Test: `test/models/task_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
test "submit_plan! parks the item awaiting approval with the plan and role" do
  item = @project.tasks.create!(title: "X", item_type: "feature", board_state: "in_progress")
  item.submit_plan!(role: "engineering", plan: "## Plan\nDo the thing")
  item.reload
  assert_equal "waiting", item.board_state
  assert_equal "awaiting_approval", item.wait_reason
  assert_equal "engineering", item.agent_role
  assert_equal "## Plan\nDo the thing", item.plan
  assert item.awaiting_approval?
end

test "ask_questions! parks the item needing input with structured questions" do
  item = @project.tasks.create!(title: "X", item_type: "feature", board_state: "in_progress")
  item.ask_questions!(questions: ["Which API key?", "Vertical or horizontal?"])
  item.reload
  assert_equal "waiting", item.board_state
  assert_equal "needs_input", item.wait_reason
  assert_equal 2, item.pending_questions.size
  assert_equal "Which API key?", item.pending_questions.first["q"]
  assert_nil item.pending_questions.first["a"]
  assert item.pending_questions.first["id"].present?
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/models/task_test.rb -n "/submit_plan|ask_questions/"`
Expected: FAIL (methods undefined).

- [ ] **Step 3: Implement**

In `app/models/task.rb`, replace the existing `mark_planned!` (lines ~306-311) — keep it but add the two new methods right after it:

```ruby
  # The planner finished and the plan is ready for the human. Parks the item in
  # `waiting:awaiting_approval` (NOT `planned` — `planned` now means "approved").
  def submit_plan!(role:, plan: nil)
    self.plan = plan if plan.present?
    self.plan_updated_at = Time.current if plan.present?
    self.agent_role = role if role.present?
    self.wait_reason = "awaiting_approval"
    update!(board_state: "waiting")
  end

  # The planner needs input before it can finish. Parks in `waiting:needs_input`
  # with structured questions for the human to answer in the browser.
  def ask_questions!(questions:, role: nil, plan: nil)
    self.plan = plan if plan.present?
    self.agent_role = role if role.present?
    self.pending_questions = Array(questions).map.with_index do |q, i|
      { "id" => "q#{i + 1}", "q" => q.to_s, "a" => nil }
    end
    self.wait_reason = "needs_input"
    update!(board_state: "waiting")
  end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/models/task_test.rb -n "/submit_plan|ask_questions/"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/models/task.rb test/models/task_test.rb
git commit -m "feat(board): submit_plan! / ask_questions! park items at the gate"
```

---

## Task 4: Model — `approve_plan!`, `record_answers!`, `request_changes!`

**Files:**
- Modify: `app/models/task.rb`
- Test: `test/models/task_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
test "approve_plan! moves an awaiting-approval item to planned and clears wait_reason" do
  item = @project.tasks.create!(title: "X", item_type: "feature", board_state: "waiting",
                                wait_reason: "awaiting_approval", agent_role: "engineering",
                                plan: "do it")
  assert item.approve_plan!
  item.reload
  assert_equal "planned", item.board_state
  assert_nil item.wait_reason
end

test "approve_plan! refuses an item that is not awaiting approval" do
  item = @project.tasks.create!(title: "X", item_type: "feature", board_state: "waiting",
                                wait_reason: "needs_input")
  assert_not item.approve_plan!
  assert_equal "waiting", item.reload.board_state
end

test "record_answers! fills answers by question id" do
  item = @project.tasks.create!(title: "X", item_type: "feature", board_state: "waiting",
                                wait_reason: "needs_input",
                                pending_questions: [{ "id" => "q1", "q" => "Key?", "a" => nil }])
  item.record_answers!("q1" => "Use Pexels")
  assert_equal "Use Pexels", item.reload.pending_questions.first["a"]
end

test "request_changes! bumps plan_version and logs the note" do
  item = @project.tasks.create!(title: "X", item_type: "feature", board_state: "waiting",
                                wait_reason: "awaiting_approval", agent_role: "engineering", plan: "v1")
  assert_equal 1, item.plan_version
  item.request_changes!(note: "Use a different template")
  item.reload
  assert_equal 2, item.plan_version
  assert_equal 1, item.comments.where(author: "you").count
  assert item.awaiting_approval?, "stays awaiting approval until the planner re-parks it"
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/models/task_test.rb -n "/approve_plan|record_answers|request_changes/"`
Expected: FAIL (methods undefined).

- [ ] **Step 3: Implement**

In `app/models/task.rb`, after `ask_questions!` add:

```ruby
  # Human clicked Approve: the plan is accepted, so the item becomes `planned`
  # (= approved & queued). The next orchestrator tick executes it. No-op unless the
  # item is actually awaiting approval.
  def approve_plan!
    return false unless awaiting_approval?
    update!(board_state: "planned", wait_reason: nil)
  end

  # Store the human's answers (keyed by question id) back into pending_questions.
  def record_answers!(answers)
    answers = answers.to_h.transform_keys(&:to_s)
    self.pending_questions = Array(pending_questions).map do |q|
      next q unless answers.key?(q["id"])
      q.merge("a" => answers[q["id"]].to_s)
    end
    save!
  end

  # Human asked for plan changes: log the note, bump the version, and keep the item
  # awaiting approval (the caller resumes the planner, which re-parks it).
  def request_changes!(note:)
    transaction do
      comments.create!(author: "you", body: "Requested changes: #{note}") if note.present?
      update!(plan_version: plan_version.to_i + 1)
    end
  end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/models/task_test.rb -n "/approve_plan|record_answers|request_changes/"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/models/task.rb test/models/task_test.rb
git commit -m "feat(board): approve_plan! / record_answers! / request_changes!"
```

---

## Task 5: API gate — convert agent-set `planned` to `waiting:awaiting_approval`

This is the load-bearing gate: any agent (including the unchanged `board-plan` command) that PATCHes `board_state: "planned"` is redirected to `waiting:awaiting_approval`. The only legitimate route to `planned` is the human Approve action (Task 7).

**Files:**
- Modify: `app/controllers/api/v1/tasks_controller.rb`
- Test: `test/integration/board_approval_gate_test.rb` (new)

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

class BoardApprovalGateTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Gate", slug: "gate-#{SecureRandom.hex(3)}", repo_path: "/tmp/g")
    @task = @project.tasks.create!(title: "Build X", item_type: "feature", board_state: "in_progress")
  end

  test "an agent PATCHing planned is gated to waiting:awaiting_approval" do
    patch "/api/v1/projects/#{@project.slug}/tasks/#{@task.id}",
          params: { task: { board_state: "planned", agent_role: "engineering", plan: "## Plan" } }
    assert_response :success
    @task.reload
    assert_equal "waiting", @task.board_state
    assert_equal "awaiting_approval", @task.wait_reason
    assert_equal "engineering", @task.agent_role
    assert_equal "## Plan", @task.plan
  end

  test "an agent can PATCH needs_input with questions" do
    patch "/api/v1/projects/#{@project.slug}/tasks/#{@task.id}",
          params: { task: { board_state: "waiting", wait_reason: "needs_input",
                            pending_questions: [{ id: "q1", q: "Which format?", a: nil }] } }
    assert_response :success
    @task.reload
    assert @task.needs_input?
    assert_equal "Which format?", @task.pending_questions.first["q"]
  end

  test "the gate does not touch in_review or done transitions" do
    patch "/api/v1/projects/#{@project.slug}/tasks/#{@task.id}",
          params: { task: { board_state: "in_review", pr_url: "https://github.com/x/y/pull/1",
                            pr_number: 1, pr_state: "open" } }
    assert_response :success
    assert_equal "in_review", @task.reload.board_state
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/integration/board_approval_gate_test.rb`
Expected: FAIL (first test: board_state stays `planned`; second: `pending_questions`/`wait_reason` not permitted).

- [ ] **Step 3: Implement**

In `app/controllers/api/v1/tasks_controller.rb`:

Add the new fields to `BOARD_FIELDS` (the `private` block):

```ruby
      BOARD_FIELDS = %i[item_type board_state agent_role position plan branch_name
                        pr_url pr_number pr_state pr_diff agent_notes changelog_summary
                        pr_mergeable conflict_resolution_at wait_reason pending_questions].freeze
```

In `task_params`, `pending_questions` is an array of hashes, so permit it explicitly. Replace `task_params` with:

```ruby
      def task_params
        raw = params[:task] || params
        permitted = raw.permit(:title, :description, :implementation_notes, :external_ref, :status,
                               :priority, :source, :environment_id, :labels_text, *BOARD_FIELDS,
                               labels: [], pending_questions: [%i[id q a]])
        permitted
      end
```

In `update`, gate `planned` BEFORE save. Replace the body of `update` with:

```ruby
      def update
        task = @project.tasks.find(params[:id])
        attrs = task_params
        # The approval gate: an agent may report a finished plan as board_state
        # "planned", but in the assisted workflow nothing executes without human
        # approval. Convert it to waiting:awaiting_approval here. The ONLY path to
        # "planned" is BoardsController#approve. (Engineering/answer agents move to
        # in_review/done/failed, never "planned", so they are unaffected.)
        if attrs[:board_state].to_s == "planned"
          attrs[:board_state] = "waiting"
          attrs[:wait_reason] = "awaiting_approval"
        end
        task.assign_attributes(attrs)
        resolve_environment(task)
        task.plan_updated_at = Time.current if task.plan_changed?
        task.finished_at ||= Time.current if task.board_state_changed? && %w[in_review done].include?(task.board_state)
        task.implemented_at ||= Time.current if task.status_changed? && %w[implemented ready_for_test].include?(task.status)
        task.save!
        if (task.saved_changes.keys & %w[title item_type priority agent_role]).any? && !task.saved_change_to_board_state?
          Turbo::StreamsChannel.broadcast_refresh_to([@project, :board])
        end
        render json: serialize(task, detailed: true).merge(next_steps: next_steps_for(task))
      end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/integration/board_approval_gate_test.rb`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add app/controllers/api/v1/tasks_controller.rb test/integration/board_approval_gate_test.rb
git commit -m "feat(board): API gates agent-set planned into waiting:awaiting_approval"
```

---

## Task 6: Routes — approve / request_changes / answer_questions

**Files:**
- Modify: `config/routes.rb`

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, next to the other `board/items/:id/*` member routes (after the `steer` line, ~line 79):

```ruby
    post  "board/items/:id/approve",          to: "boards#approve",          as: :board_item_approve
    post  "board/items/:id/request_changes",  to: "boards#request_changes",  as: :board_item_request_changes
    post  "board/items/:id/answer_questions", to: "boards#answer_questions", as: :board_item_answer_questions
```

- [ ] **Step 2: Verify the routes exist**

Run: `bin/rails routes -g board_item_approve`
Expected: shows `POST /projects/:project_id/board/items/:id/approve` → `boards#approve`.

- [ ] **Step 3: Commit**

```bash
git add config/routes.rb
git commit -m "feat(board): routes for approve / request_changes / answer_questions"
```

---

## Task 7: Controller — approve / request_changes / answer_questions

`approve` advances to `planned` and immediately runs one orchestrator step so execution starts without waiting for the daemon heartbeat. `answer_questions` and `request_changes` resume the planning session in the project folder (the existing `continue_session` pattern), carrying the answers / change-note in the resume prompt so the resumed planner picks up exactly where it left off.

**Files:**
- Modify: `app/controllers/boards_controller.rb`
- Test: `test/integration/board_test.rb`

- [ ] **Step 1: Write the failing test**

Add to `test/integration/board_test.rb`:

```ruby
test "approve advances an awaiting-approval item to planned" do
  project = Project.create!(name: "Ap", slug: "ap-#{SecureRandom.hex(3)}", repo_path: "/tmp/ap")
  task = project.tasks.create!(title: "Build", item_type: "feature", board_state: "waiting",
                               wait_reason: "awaiting_approval", agent_role: "engineering", plan: "do it")
  Autopilot::Orchestrator.stub(:run_once, nil) do
    post approve_project_board_item_path(project, task)
  end
  assert_equal "planned", task.reload.board_state
  assert_nil task.wait_reason
end

test "answer_questions stores answers and queues a resume launch" do
  project = Project.create!(name: "Aq", slug: "aq-#{SecureRandom.hex(3)}", repo_path: "/tmp/aq")
  task = project.tasks.create!(title: "Build", item_type: "feature", board_state: "waiting",
                               wait_reason: "needs_input",
                               pending_questions: [{ "id" => "q1", "q" => "Format?", "a" => nil }])
  # Give the item a prior planning launch so there is a session to resume.
  SessionLaunch.queue!(project: project, task: task, prompt: "/board-plan", model: "default",
                       permission_mode: "auto", source: "board", title: "planning",
                       pipeline_step: "planning").update!(session_id: "sess-1")

  assert_difference -> { SessionLaunch.where(source: "resume").count }, 1 do
    post answer_questions_project_board_item_path(project, task), params: { answers: { q1: "Vertical" } }
  end
  assert_equal "Vertical", task.reload.pending_questions.first["a"]
end

test "request_changes bumps the plan version and queues a resume launch" do
  project = Project.create!(name: "Rc", slug: "rc-#{SecureRandom.hex(3)}", repo_path: "/tmp/rc")
  task = project.tasks.create!(title: "Build", item_type: "feature", board_state: "waiting",
                               wait_reason: "awaiting_approval", agent_role: "engineering", plan: "v1")
  SessionLaunch.queue!(project: project, task: task, prompt: "/board-plan", model: "default",
                       permission_mode: "auto", source: "board", title: "planning",
                       pipeline_step: "planning").update!(session_id: "sess-2")

  assert_difference -> { SessionLaunch.where(source: "resume").count }, 1 do
    post request_changes_project_board_item_path(project, task), params: { note: "Different template" }
  end
  assert_equal 2, task.reload.plan_version
end
```

> Note: the named path helpers are `approve_project_board_item_path`, `answer_questions_project_board_item_path`, `request_changes_project_board_item_path` (Rails derives the `project_board_item` infix from the nested resource even though the `as:` is shorter — confirm with `bin/rails routes`; if the emitted helper differs, use the exact name `bin/rails routes` prints).

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/integration/board_test.rb -n "/approve advances|answer_questions stores|request_changes bumps/"`
Expected: FAIL (actions undefined).

- [ ] **Step 3: Implement**

In `app/controllers/boards_controller.rb`, add the three actions to the `before_action :set_task` list (line 7): append `:approve, :request_changes, :answer_questions`.

Add the actions (after `add_comment`, ~line 205):

```ruby
  # Human approved the plan on the task page / approvals inbox. Advance to planned
  # (= approved) and run one orchestrator step now so execution starts promptly.
  def approve
    if @task.approve_plan!
      Autopilot::Orchestrator.run_once(@task.project)
      redirect_to [@project, @task], notice: "Approved — execution queued."
    else
      redirect_to [@project, @task], alert: "Can't approve: the item isn't awaiting approval."
    end
  end

  # Human asked for plan changes. Log the note, bump the version, and resume the
  # planning session in the project folder so it produces a revised plan (which the
  # API re-gates to awaiting_approval).
  def request_changes
    note = params[:note].to_s.strip
    @task.request_changes!(note: note)
    resume_planner!("The user requested plan changes: #{note}\n\n" \
                    "Revise the implementation plan accordingly and PATCH it back " \
                    "(board_state:'planned' — it will be gated to await approval).")
    redirect_to [@project, @task], notice: "Sent back to the planner with your notes."
  end

  # Human answered the planner's questions. Store them and resume the planning
  # session, passing the answers so it can finalize the plan.
  def answer_questions
    @task.record_answers!(params[:answers] || {})
    answered = @task.pending_questions.map { |q| "Q: #{q['q']}\nA: #{q['a']}" }.join("\n\n")
    resume_planner!("The user answered your questions:\n\n#{answered}\n\n" \
                    "Finalize the implementation plan and PATCH it back " \
                    "(board_state:'planned' — it will be gated to await approval).")
    redirect_to [@project, @task], notice: "Answers sent — finalizing the plan."
  end
```

Add the private helper (in the `private` section, after `open_session_in_browser`):

```ruby
  # Queue a resume of the item's most recent board pipeline session, carrying an
  # instruction as the resume prompt. The host daemon spawns `claude --resume
  # <session_id>` in the project folder, so all context comes from the repo.
  def resume_planner!(instruction)
    sid = @task.resumable_session_id
    return if sid.blank?
    launch = SessionLaunch.queue!(
      project: @task.project,
      task: @task,
      prompt: instruction,
      model: "default",
      permission_mode: "auto",
      source: "resume",
      title: "re-plan: #{@task.title}".truncate(80),
      pipeline_step: "planning"
    )
    launch.update!(resume_of_session_id: sid)
  end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/integration/board_test.rb -n "/approve advances|answer_questions stores|request_changes bumps/"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/boards_controller.rb test/integration/board_test.rb
git commit -m "feat(board): approve / request_changes / answer_questions actions"
```

---

## Task 8: View — approval panel on the task page

**Files:**
- Create: `app/views/boards/_approval_panel.html.erb`
- Modify: `app/views/tasks/show.html.erb`

- [ ] **Step 1: Create the partial**

`app/views/boards/_approval_panel.html.erb`:

```erb
<%# Renders the gate UI when an item is parked in waiting. needs_input → a Q&A form;
    awaiting_approval → the plan plus Approve / Request-changes. %>
<% if task.needs_input? %>
  <%= card title: "The agent needs your input" do %>
    <%= form_with url: answer_questions_project_board_item_path(project, task), method: :post do |f| %>
      <% task.pending_questions.each do |q| %>
        <div class="mb-3">
          <label class="block text-sm text-[color:var(--color-ink)] mb-1"><%= q["q"] %></label>
          <%= text_area_tag "answers[#{q['id']}]", q["a"], rows: 2,
                class: "w-full text-sm border border-[color:var(--color-hair)] rounded-md px-2 py-1.5" %>
        </div>
      <% end %>
      <%= f.submit "Send answers", class: "text-sm text-[color:var(--color-paper)] bg-[color:var(--color-ink)] px-3 py-1.5 rounded-md" %>
    <% end %>
  <% end %>
<% elsif task.awaiting_approval? %>
  <%= card title: "Plan awaiting your approval#{task.plan_version.to_i > 1 ? " (revised v#{task.plan_version})" : ''}" do %>
    <div class="prose prose-sm max-w-none mb-4 text-[color:var(--color-ink)]">
      <%= raw(markdown(task.plan.to_s)) %>
    </div>
    <div class="flex items-center gap-2">
      <%= button_to "Approve & execute", approve_project_board_item_path(project, task),
            method: :post, class: "text-sm text-[color:var(--color-paper)] bg-[color:var(--color-ok-ink)] px-3 py-1.5 rounded-md" %>
      <%= form_with url: request_changes_project_board_item_path(project, task), method: :post, class: "flex items-center gap-2" do |f| %>
        <%= text_field_tag :note, nil, placeholder: "What should change?",
              class: "text-sm border border-[color:var(--color-hair)] rounded-md px-2 py-1.5 w-64" %>
        <%= f.submit "Request changes", class: "text-sm border border-[color:var(--color-hair)] px-3 py-1.5 rounded-md text-[color:var(--color-ink-soft)]" %>
      <% end %>
    </div>
  <% end %>
<% end %>
```

> Verify the helper used for markdown: search the codebase for how `_plan_modal.html.erb` renders `task.plan`. Run `grep -rn "markdown\|render_markdown\|Kramdown\|Commonmarker" app/helpers app/views/boards/_plan_modal.html.erb` and use the **same** helper name there instead of `markdown(...)` if it differs.

- [ ] **Step 2: Render it from the task page**

In `app/views/tasks/show.html.erb`, immediately before the `<%= card title: "Plan & direction" do %>` line (~line 60), add:

```erb
    <%= render "boards/approval_panel", project: @project, task: @task %>
```

- [ ] **Step 3: Manual verification**

Run the app, create a feature item, and PATCH it to a plan via the API to land it in `awaiting_approval`:

```bash
curl -s -X PATCH "http://localhost:1200/api/v1/projects/<slug>/tasks/<id>" \
  -H 'Content-Type: application/json' \
  -d '{"task":{"board_state":"planned","agent_role":"engineering","plan":"## Plan\n- step one"}}' | head
```

Open `http://localhost:1200/projects/<slug>/tasks/<id>` — expected: a "Plan awaiting your approval" card with the rendered plan, an **Approve & execute** button, and a **Request changes** box. Click Approve → the item moves to `planned` and a launch is queued.

- [ ] **Step 4: Commit**

```bash
git add app/views/boards/_approval_panel.html.erb app/views/tasks/show.html.erb
git commit -m "feat(board): approval panel (Q&A + Approve/Request-changes) on the task page"
```

---

## Task 9: View — gate affordance on the board row

**Files:**
- Modify: `app/views/boards/_item.html.erb`
- Test: `test/integration/board_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
test "the board surfaces an awaiting-approval item with a link to approve" do
  project = Project.create!(name: "Bd", slug: "bd-#{SecureRandom.hex(3)}", repo_path: "/tmp/bd")
  task = project.tasks.create!(title: "Needs approval", item_type: "feature", board_state: "waiting",
                               wait_reason: "awaiting_approval", agent_role: "engineering", plan: "p")
  get board_path(project)
  assert_response :success
  assert_select "a[href=?]", project_task_path(project, task)
  assert_match(/Awaiting approval|Approve/, response.body)
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/integration/board_test.rb -n "/surfaces an awaiting-approval/"`
Expected: FAIL (no "Awaiting approval" affordance).

- [ ] **Step 3: Implement**

In `app/views/boards/_item.html.erb`, find the block that renders state-specific affordances (search for `item.board_state` / `item.waiting?` / the existing badges). Add, where the per-item action chips render:

```erb
<% if item.awaiting_approval? %>
  <%= link_to "Awaiting approval ▸ review", project_task_path(item.project, item),
        class: "pill pill-quiet font-mono !py-0 !px-1.5 !text-[10px]" %>
<% elsif item.needs_input? %>
  <%= link_to "Needs your input ▸ answer", project_task_path(item.project, item),
        class: "pill pill-quiet font-mono !py-0 !px-1.5 !text-[10px]" %>
<% end %>
```

> If `_item.html.erb` has no obvious chip area, place this just after the item title link. Keep it inside the existing row container so the Turbo board refresh re-renders it.

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/integration/board_test.rb -n "/surfaces an awaiting-approval/"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/views/boards/_item.html.erb test/integration/board_test.rb
git commit -m "feat(board): board row shows awaiting-approval / needs-input affordance"
```

---

## Task 10: Document the new planner contract

**Files:**
- Modify: `docs/board/PLAN.md`

- [ ] **Step 1: Add the contract note**

Append a section to `docs/board/PLAN.md`:

```markdown
## Approval gate (assisted workflow)

The planner no longer lands items in `planned`. When `board-plan` finishes:

- If it needs input: PATCH `{ board_state: "waiting", wait_reason: "needs_input",
  pending_questions: [{ id, q, a: null }, …], agent_role, plan? }`.
- Otherwise: PATCH `{ board_state: "planned", agent_role, plan }` — the API converts
  this to `waiting:awaiting_approval` automatically (the gate). Older planners need
  no change to be gated; they only need updating to emit `pending_questions`.

`planned` is reached only when the human clicks **Approve** (POST
`/projects/:slug/board/items/:id/approve`), after which the orchestrator executes the
item with the role the planner assigned. **Request changes** / **answer questions**
resume the planning session in the project folder via `resume_of_session_id`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/board/PLAN.md
git commit -m "docs(board): document the approval-gate planner contract"
```

---

## Final verification

- [ ] **Run the full board/model/API test suites**

Run:
```bash
bin/rails test test/models/task_test.rb test/integration/board_test.rb test/integration/board_approval_gate_test.rb
```
Expected: all green.

- [ ] **Lint**

Run: `bin/rubocop app/models/task.rb app/controllers/boards_controller.rb app/controllers/api/v1/tasks_controller.rb`
Expected: no offenses (fix any per the repo's RuboCop config).

- [ ] **End-to-end smoke** (manual): create a feature item → let/Make the planner park it (API PATCH as in Task 8) → task page shows the gate → Approve → item executes (`planned → in_progress`). Then repeat with a `needs_input` PATCH → answer the questions → a resume launch is queued.

---

## Self-Review Notes

- **Spec coverage (Phase 1 slice):** gate (Tasks 1–5), in-browser Q&A + Approve/Change (Tasks 6–8), board affordance (Task 9), planner contract (Task 10). `review_ready_at`/ordering, consolidation, `/approvals` inbox + blink, and Web Push are explicitly deferred to later phase plans.
- **Execution boundary:** preserved — resume launches run in the project folder; myjira only stores status/questions/plan and relays the resume instruction.
- **Type consistency:** `pending_questions` entries use string keys `"id"/"q"/"a"` everywhere (model, API, views, tests). `wait_reason` values are exactly `needs_input` / `awaiting_approval`.
- **Open follow-up for the next phase:** the `_kanban_card.html.erb` variant of the board also needs the Task 9 affordance — handle it alongside the `/approvals` inbox plan so both board renderings stay consistent.
