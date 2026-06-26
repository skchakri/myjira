# Approve / Reject on PR changes modal + comment log — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Approve / Reject actions to the PR changes modal (approve → merge → Done; reject → Failed, PR left open) and an append-only comment log on each board item, with a status control on the task page so a Failed item can be commented and moved back to Pending in one place.

**Architecture:** A new `TaskComment` model backs the append-only log. `Task#reject_pr!` is a local-only transition (no GitHub side effect). Approve reuses the existing `Task#request_merge!` daemon flow. The web surfaces it through `BoardsController` (reject_pr, add_comment) and the existing `update_item`; agents post comments through a nested API `CommentsController`. Views: action bar in the PR modal, a reject button in the board row, and a Comments card + status control on the task page.

**Tech Stack:** Rails 8.1, PostgreSQL (UUID PKs), Hotwire (Turbo + Stimulus `auto-submit`), Tailwind v4 with CSS-variable tokens, Minitest with the repo's custom `StubSupport` helper (no mocha/webmock).

**Spec:** `docs/superpowers/specs/2026-06-26-approve-reject-pr-changes-design.md`

**Conventions confirmed:**
- All tables use `id: :uuid, default: -> { "gen_random_uuid()" }`. Migrations declare `ActiveRecord::Migration[8.1]`.
- Run a single test file: `bin/rails test test/path/to_test.rb`. Run one test by name: append `-n "/substring/"`. Lint: `bin/rubocop`.
- Board routes live inside the `resources :projects` block in `config/routes.rb` (helpers like `board_item_merge_path(project, item)`).
- Board view tokens: `var(--color-pass-ink)`, `--color-pass-wash`, `--color-fail-ink`, `--color-fail-wash`, `hair-all`, `pill`, `pill-accent`. The task page (`tasks/show.html.erb`) uses the older `slate-*` palette and the `card(title:)` helper.

---

## File Structure

- Create: `db/migrate/20260626000001_create_task_comments.rb` — the comments table.
- Create: `app/models/task_comment.rb` — comment model.
- Modify: `app/models/task.rb` — `has_many :comments`; `reject_pr!`.
- Modify: `app/controllers/boards_controller.rb` — `reject_pr`, `add_comment`; extend `set_task`; `update_item` redirect branch.
- Modify: `config/routes.rb` — web reject/comment routes; API nested `comments`.
- Create: `app/controllers/api/v1/comments_controller.rb` — agent-facing comment create/index.
- Modify: `app/controllers/tasks_controller.rb` — load `@comments` for the show page.
- Modify: `app/views/boards/_pr_modal.html.erb` — approve/reject action bar.
- Modify: `app/views/boards/_item.html.erb` — reject button in the row.
- Modify: `app/views/tasks/show.html.erb` — Comments card + status control.
- Modify: `test/integration/board_test.rb` — controller/route/view tests.
- Modify: `test/models/project_test.rb`? No — Create: `test/models/task_comment_test.rb` and add Task model tests to a new `test/models/task_test.rb`.

---

## Task 1: TaskComment model + migration

**Files:**
- Create: `db/migrate/20260626000001_create_task_comments.rb`
- Create: `app/models/task_comment.rb`
- Modify: `app/models/task.rb:48` (after `has_many :session_launches`)
- Test: `test/models/task_comment_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/models/task_comment_test.rb`:

```ruby
require "test_helper"

class TaskCommentTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "TC", slug: "tc-#{SecureRandom.hex(3)}", repo_path: "/tmp/tc")
    @task = @project.tasks.create!(title: "Item", item_type: "task")
  end

  test "requires a body" do
    c = @task.comments.build(author: "you", body: "")
    refute c.valid?
    assert_includes c.errors[:body], "can't be blank"
  end

  test "defaults author to 'you' and belongs to its task" do
    c = @task.comments.create!(body: "first note")
    assert_equal "you", c.author
    assert_equal @task.id, c.task_id
  end

  test "task#comments returns them oldest-first" do
    older = @task.comments.create!(body: "older", created_at: 2.minutes.ago)
    newer = @task.comments.create!(body: "newer")
    assert_equal [older.id, newer.id], @task.comments.pluck(:id)
  end

  test "deleting a task deletes its comments" do
    @task.comments.create!(body: "bye")
    assert_difference -> { TaskComment.count }, -1 do
      @task.destroy
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/task_comment_test.rb`
Expected: FAIL — `NameError: uninitialized constant TaskComment` (or table missing).

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260626000001_create_task_comments.rb`:

```ruby
# Append-only notes on a board item — left by a human on the board/task page or
# posted by a board agent via the API. Surfaced as a dated log on the task page.
class CreateTaskComments < ActiveRecord::Migration[8.1]
  def change
    create_table :task_comments, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :task, type: :uuid, null: false, foreign_key: true, index: true
      t.string :author, null: false, default: "you"
      t.text :body, null: false
      t.timestamps
    end
  end
end
```

- [ ] **Step 4: Write the model**

Create `app/models/task_comment.rb`:

```ruby
# A single append-only note on a board item (Task). author is "you" for notes
# added from the web, or a role/name for notes posted by an agent via the API.
class TaskComment < ApplicationRecord
  belongs_to :task

  validates :body, presence: true
end
```

- [ ] **Step 5: Add the association to Task**

In `app/models/task.rb`, after the `has_many :session_launches, dependent: :nullify` line (currently line 48), add:

```ruby
  has_many :comments, -> { order(created_at: :asc) }, class_name: "TaskComment", dependent: :destroy
```

- [ ] **Step 6: Run the migration**

Run: `bin/rails db:migrate`
Expected: creates `task_comments`; `db/schema.rb` updated.

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/models/task_comment_test.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 8: Commit**

```bash
git add db/migrate/20260626000001_create_task_comments.rb db/schema.rb app/models/task_comment.rb app/models/task.rb test/models/task_comment_test.rb
git commit -m "Add TaskComment model — append-only board item comments"
```

---

## Task 2: Task#reject_pr!

**Files:**
- Modify: `app/models/task.rb` (after `request_merge!`, around line 116)
- Test: `test/models/task_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/models/task_test.rb`:

```ruby
require "test_helper"

class TaskTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "T", slug: "t-#{SecureRandom.hex(3)}", repo_path: "/tmp/t")
  end

  def in_review_item(**attrs)
    @project.tasks.create!({ title: "Item", item_type: "task", board_state: "in_review",
                             pr_url: "https://github.com/x/y/pull/3", pr_number: 3, pr_state: "open" }.merge(attrs))
  end

  test "reject_pr! moves an in_review item to failed and leaves the PR untouched" do
    item = in_review_item
    assert item.reject_pr!
    item.reload
    assert_equal "failed", item.board_state
    assert_equal "https://github.com/x/y/pull/3", item.pr_url, "PR is left open on GitHub"
    assert_equal "open", item.pr_state
  end

  test "reject_pr! does not increment autopilot_attempts" do
    item = in_review_item(autopilot_attempts: 0)
    item.reject_pr!
    assert_equal 0, item.reload.autopilot_attempts
  end

  test "reject_pr! with a reason logs a comment and stamps agent_notes" do
    item = in_review_item
    assert_difference -> { item.comments.count }, 1 do
      item.reject_pr!(note: "needs design review")
    end
    assert_equal "Rejected: needs design review", item.comments.last.body
    assert_equal "Rejected: needs design review", item.reload.agent_notes
  end

  test "reject_pr! is a no-op unless in_review with a PR" do
    planned = @project.tasks.create!(title: "P", item_type: "task", board_state: "planned")
    refute planned.reject_pr!
    assert_equal "planned", planned.reload.board_state

    no_pr = @project.tasks.create!(title: "N", item_type: "task", board_state: "in_review")
    refute no_pr.reject_pr!
    assert_equal "in_review", no_pr.reload.board_state
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/task_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'reject_pr!'`.

- [ ] **Step 3: Implement reject_pr!**

In `app/models/task.rb`, immediately after the `request_merge!` method (the `end` on the line after `update!(merge_requested_at: Time.current)`, around line 116), add:

```ruby
  # "Reject" on the board/PR modal: a human declined these changes. Move the item
  # to failed but leave the PR open on GitHub (the human may still inspect or fix
  # it). Unlike mark_failed!, this does NOT bump autopilot_attempts, so re-queuing
  # the item to pending lets autopilot pick it up again. An optional reason is
  # logged as a comment and shown on the board row via agent_notes.
  def reject_pr!(note: nil)
    return false unless board_state == "in_review" && pr_url.present?
    if note.present?
      comments.create!(author: "you", body: "Rejected: #{note}")
      self.agent_notes = "Rejected: #{note}".truncate(500)
    end
    update!(board_state: "failed", merge_requested_at: nil)
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/models/task_test.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add app/models/task.rb test/models/task_test.rb
git commit -m "Add Task#reject_pr! — local-only reject to failed, PR left open"
```

---

## Task 3: BoardsController reject_pr + add_comment + routes + update_item redirect

**Files:**
- Modify: `config/routes.rb` (after the `board/items/:id/merge` line, currently line 64)
- Modify: `app/controllers/boards_controller.rb:7` (set_task list) and add actions; `update_item` redirect branch
- Test: `test/integration/board_test.rb`

- [ ] **Step 1: Write the failing tests**

Append to `test/integration/board_test.rb`, before the final `end`:

```ruby
  test "reject_pr moves an in_review item to failed and logs the reason" do
    @b.update!(board_state: "in_review", pr_url: "https://github.com/x/y/pull/2",
               pr_number: 2, pr_state: "open")
    assert_difference -> { @b.comments.count }, 1 do
      post board_item_reject_path(@project, @b), params: { reason: "conflicts with main" }
    end
    assert_redirected_to board_path(@project)
    assert_equal "failed", @b.reload.board_state
    assert_equal "https://github.com/x/y/pull/2", @b.pr_url
    assert_equal "Rejected: conflicts with main", @b.comments.last.body
  end

  test "reject_pr on a non-review item redirects with an alert" do
    post board_item_reject_path(@project, @a) # @a is pending, no PR
    assert_redirected_to board_path(@project)
    assert_equal "pending", @a.reload.board_state
  end

  test "add_comment appends a comment and returns to the task page" do
    assert_difference -> { @a.comments.count }, 1 do
      post board_item_comments_path(@project, @a), params: { comment: { body: "moving back, see conflicts" } }
    end
    assert_redirected_to project_task_path(@project, @a)
    assert_equal "you", @a.comments.last.author
    assert_equal "moving back, see conflicts", @a.comments.last.body
  end

  test "add_comment ignores a blank body" do
    assert_no_difference -> { @a.comments.count } do
      post board_item_comments_path(@project, @a), params: { comment: { body: "  " } }
    end
    assert_redirected_to project_task_path(@project, @a)
  end

  test "update_item with return_to=task redirects to the task page" do
    patch board_item_path(@project, @a), params: { task: { board_state: "pending" }, return_to: "task" }
    assert_redirected_to project_task_path(@project, @a)
    assert_equal "pending", @a.reload.board_state
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/integration/board_test.rb -n "/reject_pr|add_comment|return_to/"`
Expected: FAIL — `NoMethodError: undefined method 'board_item_reject_path'` (routes not defined yet).

- [ ] **Step 3: Add the web routes**

In `config/routes.rb`, directly after the existing line
`post  "board/items/:id/merge",     to: "boards#request_merge", as: :board_item_merge`
add:

```ruby
    post  "board/items/:id/reject",    to: "boards#reject_pr",   as: :board_item_reject
    post  "board/items/:id/comments",  to: "boards#add_comment", as: :board_item_comments
```

- [ ] **Step 4: Extend set_task and add the actions**

In `app/controllers/boards_controller.rb`, change the `before_action :set_task` line (line 7) to include the new actions:

```ruby
  before_action :set_task, only: [:update_item, :pick_up, :run_tests, :request_merge, :reject_pr, :add_comment, :plan, :pr]
```

Replace the `update_item` method body's final two lines (the `refresh_board!...` and `head :no_content`) so it reads:

```ruby
  def update_item
    @task.assign_attributes(update_params)
    @task.plan_updated_at = Time.current if @task.plan_changed?
    @task.save!
    refresh_board! unless @task.saved_change_to_board_state? # model already broadcast that
    if params[:return_to] == "task"
      redirect_to [@task.project, @task], notice: "Status updated."
    else
      head :no_content
    end
  end
```

Then, immediately after the `request_merge` method (after its closing `end`, around line 97), add:

```ruby
  # "Reject" on an in_review item / PR modal: decline the changes. Moves to failed
  # and leaves the PR open on GitHub; an optional reason is logged as a comment.
  def reject_pr
    if @task.reject_pr!(note: params[:reason])
      refresh_board!
      redirect_to board_path(@project), notice: "Rejected — moved to Failed. The PR is left open on GitHub."
    else
      redirect_to board_path(@project), alert: "Can't reject: the item must be in review with an open PR."
    end
  end

  # Add an append-only note to an item (from the board or task page). Blank bodies
  # are ignored. Always returns to the task page where the comment log lives.
  def add_comment
    body = params.dig(:comment, :body).to_s.strip
    @task.comments.create!(author: "you", body: body) if body.present?
    redirect_to [@project, @task], notice: ("Comment added." if body.present?)
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/integration/board_test.rb -n "/reject_pr|add_comment|return_to/"`
Expected: PASS (5 runs, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/controllers/boards_controller.rb test/integration/board_test.rb
git commit -m "Board: reject_pr + add_comment actions; update_item task redirect"
```

---

## Task 4: API CommentsController (agents post comments)

**Files:**
- Modify: `config/routes.rb` (inside the API `resources :tasks` block, around line 11-14)
- Create: `app/controllers/api/v1/comments_controller.rb`
- Test: `test/integration/board_test.rb`

- [ ] **Step 1: Write the failing tests**

Append to `test/integration/board_test.rb`, before the final `end`:

```ruby
  test "api creates a comment authored by an agent" do
    assert_difference -> { @a.comments.count }, 1 do
      post "/api/v1/projects/#{@project.slug}/tasks/#{@a.id}/comments",
           params: { comment: { author: "engineering", body: "rebased on main, conflict resolved" } }
    end
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "engineering", body["author"]
    assert_equal "rebased on main, conflict resolved", body["body"]
  end

  test "api comment defaults author to agent and rejects a blank body" do
    post "/api/v1/projects/#{@project.slug}/tasks/#{@a.id}/comments", params: { comment: { body: "ok" } }
    assert_response :created
    assert_equal "agent", JSON.parse(response.body)["author"]

    post "/api/v1/projects/#{@project.slug}/tasks/#{@a.id}/comments", params: { comment: { body: "" } }
    assert_response :unprocessable_entity
  end

  test "api lists comments oldest-first" do
    @a.comments.create!(body: "one", created_at: 2.minutes.ago)
    @a.comments.create!(body: "two")
    get "/api/v1/projects/#{@project.slug}/tasks/#{@a.id}/comments"
    assert_response :success
    bodies = JSON.parse(response.body).map { |c| c["body"] }
    assert_equal %w[one two], bodies
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/integration/board_test.rb -n "/api.*comment/"`
Expected: FAIL — routing error (no route matches the comments path).

- [ ] **Step 3: Add the API route**

In `config/routes.rb`, inside the API `resources :tasks ... do` block (the one with `member { post :finish }` and `resources :follow_up_tasks`), add a nested resource:

```ruby
          resources :comments, only: [:index, :create]
```

So the block reads:

```ruby
        resources :tasks,        only: [:index, :show, :create, :update] do
          member { post :finish } # agent signals "coding done" → fire the test leg
          resources :follow_up_tasks, only: [:index, :create], path: "follow_ups"
          resources :comments, only: [:index, :create]
        end
```

- [ ] **Step 4: Create the controller**

Create `app/controllers/api/v1/comments_controller.rb`:

```ruby
module Api
  module V1
    # Append-only comments on a board item. Lets board agents (engineering /
    # debugger / answer) post progress or conflict notes that show in the same
    # log a human reads on the task page. author defaults to "agent".
    class CommentsController < BaseController
      before_action :find_project!

      def index
        render json: task.comments.map { |c| serialize(c) }
      end

      def create
        comment = task.comments.create!(comment_params)
        render json: serialize(comment), status: :created
      end

      private

      def task
        @task ||= @project.tasks.find(params[:task_id])
      end

      def comment_params
        raw = params[:comment] || params
        permitted = raw.permit(:author, :body)
        permitted[:author] = permitted[:author].presence || "agent"
        permitted
      end

      def serialize(comment)
        { id: comment.id, author: comment.author, body: comment.body, created_at: comment.created_at }
      end
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/integration/board_test.rb -n "/api.*comment/"`
Expected: PASS (3 runs, 0 failures). The blank-body case raises `RecordInvalid`, which `BaseController` rescues to a 422.

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/controllers/api/v1/comments_controller.rb test/integration/board_test.rb
git commit -m "API: nested task comments endpoint for board agents"
```

---

## Task 5: PR changes modal — Approve / Reject action bar

**Files:**
- Modify: `app/views/boards/_pr_modal.html.erb`
- Test: `test/integration/board_test.rb`

- [ ] **Step 1: Write the failing test**

Append to `test/integration/board_test.rb`, before the final `end`:

```ruby
  test "pr modal shows approve and reject for an in_review item with a PR" do
    @b.update!(board_state: "in_review", pr_url: "https://github.com/x/y/pull/9",
               pr_number: 9, pr_state: "open", pr_diff: "+ x")
    get board_item_pr_path(@project, @b)
    assert_response :success
    assert_select "form[action=?]", board_item_merge_path(@project, @b)
    assert_select "form[action=?]", board_item_reject_path(@project, @b)
    assert_match "Approve", response.body
    assert_match "Reject", response.body
  end

  test "pr modal hides the action bar once a merge is requested" do
    @b.update!(board_state: "in_review", pr_url: "https://github.com/x/y/pull/9",
               pr_number: 9, pr_state: "open", merge_requested_at: Time.current)
    get board_item_pr_path(@project, @b)
    assert_response :success
    assert_select "form[action=?]", board_item_merge_path(@project, @b), count: 0
    assert_match "Merging", response.body
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/integration/board_test.rb -n "/pr modal shows approve|pr modal hides/"`
Expected: FAIL — no form matching `board_item_reject_path`.

- [ ] **Step 3: Add the action bar to the modal**

In `app/views/boards/_pr_modal.html.erb`, replace the closing of the scrollable body and frame (currently lines 31-34):

```erb
      </div>
    </div>
  </div>
<% end %>
```

with a footer action bar inserted before the closing `</div>` of the `.paper` panel:

```erb
      </div>

      <% if task.board_state == "in_review" && task.pr? %>
        <footer class="flex items-center justify-end gap-2 px-4 py-3 hair-t">
          <% if task.merge_requested? %>
            <span class="text-sm text-[color:var(--color-amber-ink)] animate-pulse"
                  title="Merging on GitHub… moves to Done when confirmed">⋯ Merging…</span>
          <% else %>
            <%= form_with url: board_item_reject_path(task.project, task), method: :post,
                  data: { turbo_confirm: "Reject PR ##{task.pr_number}? It moves to Failed (the PR stays open on GitHub)." },
                  class: "flex items-center gap-2" do %>
              <%= text_field_tag :reason, nil, placeholder: "reason (optional)",
                    class: "text-xs hair-all rounded px-2 py-1 bg-[color:var(--color-paper-sunk)] text-[color:var(--color-ink)] w-48" %>
              <%= submit_tag "✕ Reject",
                    class: "text-sm px-3 py-1.5 rounded cursor-pointer text-[color:var(--color-fail-ink)] hover:bg-[color:var(--color-fail-wash)]" %>
            <% end %>
            <%= button_to "✓ Approve & merge", board_item_merge_path(task.project, task), method: :post,
                  form: { data: { turbo_confirm: "Approve and merge PR ##{task.pr_number}? It will merge on GitHub and move to Done." } },
                  class: "text-sm px-3 py-1.5 rounded cursor-pointer text-[color:var(--color-pass-ink)] hover:bg-[color:var(--color-pass-wash)] hair-all" %>
          <% end %>
        </footer>
      <% end %>
    </div>
  </div>
<% end %>
```

Note: keep the existing `<div class="p-4 max-h-[72vh] overflow-y-auto">…</div>` block intact above — only its closing `</div>` is the first line shown above. The footer is a sibling of that scroll body, inside the `.paper` panel.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/integration/board_test.rb -n "/pr modal shows approve|pr modal hides/"`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 5: Verify `hair-t` exists (fallback if not)**

Run: `grep -rn "hair-t" app/assets app/views | head -3`
If `hair-t` is not defined anywhere, replace `hair-t` in the footer with `hair-b` is wrong (that's a bottom border) — instead use an inline top border: change `class="… hair-t"` to `class="… border-t border-[color:var(--color-hair-soft)]"`. (`hair-b` and `--color-hair-soft` are both used in `ui_helper.rb`, so they exist.)

- [ ] **Step 6: Commit**

```bash
git add app/views/boards/_pr_modal.html.erb test/integration/board_test.rb
git commit -m "PR modal: Approve & merge / Reject action bar"
```

---

## Task 6: Board row — Reject button

**Files:**
- Modify: `app/views/boards/_item.html.erb` (the "Pick up" action cell, lines 70-86)
- Test: `test/integration/board_test.rb`

- [ ] **Step 1: Write the failing test**

Append to `test/integration/board_test.rb`, before the final `end`:

```ruby
  test "board row shows a reject button for an in_review item with a PR" do
    @b.update!(board_state: "in_review", pr_url: "https://github.com/x/y/pull/5",
               pr_number: 5, pr_state: "open")
    get board_path(@project)
    assert_response :success
    assert_select "li[data-id='#{@b.id}'] form[action=?]", board_item_reject_path(@project, @b)
    assert_select "li[data-id='#{@b.id}'] form[action=?]", board_item_merge_path(@project, @b)
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/integration/board_test.rb -n "/board row shows a reject/"`
Expected: FAIL — no reject form inside the row.

- [ ] **Step 3: Add the reject button to the row**

In `app/views/boards/_item.html.erb`, the final action cell currently is (lines 70-86):

```erb
  <!-- Pick up -->
  <div class="shrink-0 w-7 text-center">
    <% if item.actionable? %>
      <%= button_to "▶", board_item_pick_up_path(item.project, item), method: :post,
            class: "text-xs px-1.5 py-0.5 hair-all rounded text-[color:var(--color-ink-soft)] hover:text-[color:var(--color-amber-ink)] cursor-pointer",
            title: "Pick up — run #{Board::Pipeline.next_step_for(item)} agent" %>
    <% elsif item.board_state == "in_review" && item.pr? %>
      <% if item.merge_requested? %>
        <span class="text-xs text-[color:var(--color-amber-ink)] animate-pulse" title="Merging on GitHub… moves to Done when confirmed" aria-label="Merging">⋯</span>
      <% else %>
        <%= button_to "✓", board_item_merge_path(item.project, item), method: :post,
              form: { data: { turbo_confirm: "Approve and merge PR ##{item.pr_number}? It will merge on GitHub and move to Done." } },
              class: "text-xs px-1.5 py-0.5 hair-all rounded text-[color:var(--color-pass-ink)] hover:bg-[color:var(--color-pass-wash)] cursor-pointer",
              title: "Approve & merge PR → Done" %>
      <% end %>
    <% end %>
  </div>
```

Widen the cell and add the reject button next to ✓. Replace the whole block above with:

```erb
  <!-- Pick up / review -->
  <div class="shrink-0 w-16 text-center flex items-center justify-center gap-1">
    <% if item.actionable? %>
      <%= button_to "▶", board_item_pick_up_path(item.project, item), method: :post,
            class: "text-xs px-1.5 py-0.5 hair-all rounded text-[color:var(--color-ink-soft)] hover:text-[color:var(--color-amber-ink)] cursor-pointer",
            title: "Pick up — run #{Board::Pipeline.next_step_for(item)} agent" %>
    <% elsif item.board_state == "in_review" && item.pr? %>
      <% if item.merge_requested? %>
        <span class="text-xs text-[color:var(--color-amber-ink)] animate-pulse" title="Merging on GitHub… moves to Done when confirmed" aria-label="Merging">⋯</span>
      <% else %>
        <%= button_to "✓", board_item_merge_path(item.project, item), method: :post,
              form: { data: { turbo_confirm: "Approve and merge PR ##{item.pr_number}? It will merge on GitHub and move to Done." } },
              class: "text-xs px-1.5 py-0.5 hair-all rounded text-[color:var(--color-pass-ink)] hover:bg-[color:var(--color-pass-wash)] cursor-pointer",
              title: "Approve & merge PR → Done" %>
        <%= button_to "✕", board_item_reject_path(item.project, item), method: :post,
              form: { data: { turbo_confirm: "Reject PR ##{item.pr_number}? It moves to Failed (the PR stays open on GitHub)." } },
              class: "text-xs px-1.5 py-0.5 hair-all rounded text-[color:var(--color-fail-ink)] hover:bg-[color:var(--color-fail-wash)] cursor-pointer",
              title: "Reject PR → Failed" %>
      <% end %>
    <% end %>
  </div>
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/integration/board_test.rb -n "/board row shows a reject/"`
Expected: PASS (1 run, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add app/views/boards/_item.html.erb test/integration/board_test.rb
git commit -m "Board row: Reject button for in_review items"
```

---

## Task 7: Task page — Comments card + status control

**Files:**
- Modify: `app/controllers/tasks_controller.rb:6-8` (show action)
- Modify: `app/views/tasks/show.html.erb` (header actions + a new card)
- Test: `test/integration/board_test.rb`

- [ ] **Step 1: Write the failing test**

Append to `test/integration/board_test.rb`, before the final `end`:

```ruby
  test "task page shows the comment log and a status control" do
    @a.comments.create!(author: "you", body: "first human note")
    @a.comments.create!(author: "engineering", body: "agent reply note")
    get project_task_path(@project, @a)
    assert_response :success
    assert_match "Comments", response.body
    assert_match "first human note", response.body
    assert_match "agent reply note", response.body
    # add-comment form posts to the board comments route
    assert_select "form[action=?]", board_item_comments_path(@project, @a)
    # inline status control posts to update_item with return_to=task
    assert_select "form[action=?] input[name=return_to][value=task]", board_item_path(@project, @a)
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/integration/board_test.rb -n "/task page shows the comment log/"`
Expected: FAIL — "Comments" / the forms are not present.

- [ ] **Step 3: Load comments in the controller**

In `app/controllers/tasks_controller.rb`, change the `show` action (lines 5-8) to:

```ruby
  def show
    @test_plans = @task.test_plans.order(created_at: :desc)
    @follow_ups = @task.follow_up_tasks.order(created_at: :desc)
    @comments = @task.comments
  end
```

- [ ] **Step 4: Add the status control to the header**

In `app/views/tasks/show.html.erb`, in the header actions `div` (currently lines 23-26, the one holding "Edit" and "+ Follow-up"), add an inline status form as the first child so it reads:

```erb
  <div class="flex items-center gap-2">
    <%= form_with url: board_item_path(@project, @task), method: :patch, scope: :task,
          data: { controller: "auto-submit" }, class: "flex items-center" do |f| %>
      <%= hidden_field_tag :return_to, "task" %>
      <%= f.select :board_state,
            options_for_select(Task::BOARD_STATES.map { |s| [Task::BOARD_STATE_LABELS[s], s] }, @task.board_state),
            {}, { data: { action: "change->auto-submit#submit" }, "aria-label": "Board status",
                  class: "text-sm border border-slate-200 rounded-md px-2 py-1.5 text-slate-700" } %>
    <% end %>
    <%= link_to "Edit", edit_project_task_path(@project, @task), class: "text-sm text-slate-600 hover:text-slate-900 px-3 py-1.5 border border-slate-200 rounded-md" %>
    <%= link_to "+ Follow-up", new_project_task_follow_up_path(@project, @task), class: "text-sm text-white bg-rose-700 hover:bg-rose-800 px-3 py-1.5 rounded-md" %>
  </div>
```

- [ ] **Step 5: Add the Comments card**

In `app/views/tasks/show.html.erb`, inside the left column (the `lg:col-span-2` div), add a new card after the "Implementation notes" card (after its `<% end %>`, currently around line 82):

```erb
    <%= card title: "Comments" do %>
      <% if @comments.any? %>
        <ul class="space-y-3 mb-4">
          <% @comments.each do |c| %>
            <li>
              <div class="flex items-baseline gap-2">
                <span class="text-xs font-medium text-slate-700"><%= c.author %></span>
                <span class="text-xs text-slate-400" title="<%= format_time(c.created_at) %>"><%= ago(c.created_at) %></span>
              </div>
              <p class="text-sm text-slate-800 whitespace-pre-wrap mt-0.5"><%= c.body %></p>
            </li>
          <% end %>
        </ul>
      <% else %>
        <p class="text-sm text-slate-500 mb-4">No comments yet.</p>
      <% end %>

      <%= form_with url: board_item_comments_path(@project, @task), method: :post, class: "space-y-2" do %>
        <%= text_area_tag "comment[body]", nil, rows: 2, placeholder: "Add a comment… (e.g. why you're moving this back to Pending)",
              class: "w-full text-sm border border-slate-200 rounded-md px-3 py-2" %>
        <div class="text-right">
          <%= submit_tag "Post", class: "text-sm text-white bg-slate-900 hover:bg-slate-700 px-3 py-1.5 rounded-md cursor-pointer" %>
        </div>
      <% end %>
    <% end %>
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bin/rails test test/integration/board_test.rb -n "/task page shows the comment log/"`
Expected: PASS (1 run, 0 failures).

- [ ] **Step 7: Commit**

```bash
git add app/controllers/tasks_controller.rb app/views/tasks/show.html.erb test/integration/board_test.rb
git commit -m "Task page: comment log + inline status control"
```

---

## Task 8: Full suite + lint + final commit

- [ ] **Step 1: Run the full test suite**

Run: `bin/rails test`
Expected: all green (0 failures, 0 errors). If a failure references a missing CSS class or helper, fix per Task 5 Step 5 guidance.

- [ ] **Step 2: Lint**

Run: `bin/rubocop`
Expected: no offences. If offences appear, run `bin/rubocop -A` for safe autocorrections, then re-run `bin/rubocop` and fix any remaining by hand.

- [ ] **Step 3: Manual smoke (optional but recommended)**

Run the app and verify by clicking through:
- Open the board for a project with an `in_review` item that has a PR → click the `#PR` pill → the modal shows **✓ Approve & merge** and **✕ Reject** (with a reason box).
- Click Reject with a reason → item moves to **Failed**; open the item → the Comments card shows "Rejected: …"; the header status dropdown can move it to **Pending**; add another comment.

Use the `/run` skill or: open `http://localhost:1200`.

- [ ] **Step 4: Final commit (only if Steps 1-2 made changes)**

```bash
git add -A
git commit -m "Approve/Reject PR changes + comment log: tests green, lint clean"
```

---

## Self-Review (completed by plan author)

- **Spec coverage:** Approve in modal (Task 5) ✓; Reject → Failed, PR open (Tasks 2,3,5,6) ✓; comment log model + UI (Tasks 1,7) ✓; status control to move → Pending on the task page (Task 7) ✓; optional reason (Tasks 2,3,5) ✓; no autopilot-attempt bump (Task 2) ✓; API for agents (Task 4) ✓; no daemon change (reject is local-only) ✓; Minitest + custom stub, no mocha/webmock ✓; rubocop (Task 8) ✓.
- **Placeholder scan:** none — every code/test step contains full content.
- **Type/name consistency:** `reject_pr!(note:)`, `board_item_reject_path`, `board_item_comments_path`, `return_to=task`, `TaskComment`, `has_many :comments` used consistently across model, controller, routes, views, and tests.
