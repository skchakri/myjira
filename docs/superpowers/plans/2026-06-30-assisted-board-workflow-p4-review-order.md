# Assisted Board Workflow — Phase 4: immutable in_review ordering

> REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`).

**Goal:** The `in_review` queue is ordered strictly by **when development finished** (oldest-first), is not user-reorderable, and PRs merge in that same order.

**Architecture:** Stamp an immutable `review_ready_at` once when an item enters `in_review` (`mark_in_review!`). Order the `/review` page, the board's in_review group, and the `awaiting_merge` merge train by `review_ready_at ASC`. `BoardsController#reorder` refuses to restamp `in_review` positions, and the in_review board group is not a sortable list.

**Spec:** `docs/superpowers/specs/2026-06-30-assisted-board-workflow-design.md` (see "in_review Ordering").

---

## Task 1: Migration — `review_ready_at` (+ backfill)

**Files:** Create `db/migrate/20260630000003_add_review_ready_at_to_tasks.rb`

- [ ] Write:

```ruby
class AddReviewReadyAtToTasks < ActiveRecord::Migration[8.0]
  def up
    add_column :tasks, :review_ready_at, :datetime
    # Backfill existing in_review items so their order is stable immediately.
    execute "UPDATE tasks SET review_ready_at = COALESCE(finished_at, updated_at) WHERE board_state = 'in_review'"
  end

  def down
    remove_column :tasks, :review_ready_at
  end
end
```

- [ ] `bin/rails db:migrate` — expect `review_ready_at` on `tasks`.
- [ ] Commit.

---

## Task 2: Model — stamp once + ordered scopes

**Files:** `app/models/task.rb`; Test `test/models/task_test.rb`

- [ ] Test:

```ruby
test "mark_in_review! stamps review_ready_at once and never overwrites it" do
  item = @project.tasks.create!(title: "X", item_type: "feature", board_state: "in_progress")
  item.mark_in_review!(pr_url: "https://github.com/x/y/pull/1", pr_number: 1)
  first = item.reload.review_ready_at
  assert first.present?
  item.update!(pr_synced_at: Time.current) # a later sync
  item.mark_in_review!(pr_url: "https://github.com/x/y/pull/1", pr_number: 1)
  assert_equal first.to_i, item.reload.review_ready_at.to_i, "review_ready_at is immutable"
end

test "awaiting_merge is ordered by review_ready_at ascending" do
  newer = in_review_item(merge_requested_at: Time.current, review_ready_at: 1.minute.ago)
  older = in_review_item(merge_requested_at: Time.current, review_ready_at: 1.hour.ago)
  assert_equal [older.id, newer.id], @project.tasks.awaiting_merge.pluck(:id)
end
```

- [ ] Run → FAIL.
- [ ] Implement in `app/models/task.rb`:

In `mark_in_review!`, add to the `assign_attributes` block:

```ruby
      review_ready_at: review_ready_at || Time.current,
```

Order the `awaiting_merge` scope (replace it):

```ruby
  scope :awaiting_merge, lambda {
    where(board_state: "in_review").where.not(merge_requested_at: nil)
      .order(Arel.sql("review_ready_at ASC NULLS LAST, created_at ASC"))
  }
```

- [ ] Run → PASS. Commit.

---

## Task 3: Order the /review page and the board in_review group

**Files:** `app/controllers/reviews_controller.rb`, `app/models/project.rb`; Test `test/integration/board_test.rb`

- [ ] Test (board_test.rb) — board renders in_review oldest-finished first:

```ruby
test "the in_review board group is ordered by review_ready_at ascending" do
  project = Project.create!(name: "Ro", slug: "ro-#{SecureRandom.hex(3)}", repo_path: "/tmp/ro")
  newer = project.tasks.create!(title: "Newer review", item_type: "feature", board_state: "in_review",
                                pr_url: "https://github.com/x/y/pull/2", pr_number: 2, review_ready_at: 1.minute.ago)
  older = project.tasks.create!(title: "Older review", item_type: "feature", board_state: "in_review",
                                pr_url: "https://github.com/x/y/pull/1", pr_number: 1, review_ready_at: 1.hour.ago)
  groups = project.board_groups
  in_review = groups.find { |state, _| state == "in_review" }.last
  assert_equal [older.id, newer.id], in_review.map(&:id)
end
```

- [ ] Run → FAIL.
- [ ] Implement — `app/models/project.rb#board_groups`, after `items = grouped[state]`:

```ruby
      items = items.sort_by { |t| t.review_ready_at || t.created_at } if state == "in_review" && items
```

- [ ] `app/controllers/reviews_controller.rb` — replace the `.order(...)` line:

```ruby
                .order("projects.name ASC", Arel.sql("tasks.review_ready_at ASC NULLS LAST"))
```

- [ ] Run → PASS. Commit.

---

## Task 4: Lock reordering of in_review (server + UI)

**Files:** `app/controllers/boards_controller.rb`, `app/views/boards/_group.html.erb`; Test `test/integration/board_test.rb`

- [ ] Test (board_test.rb):

```ruby
test "reorder does not restamp position on in_review items" do
  project = Project.create!(name: "Lk", slug: "lk-#{SecureRandom.hex(3)}", repo_path: "/tmp/lk")
  item = project.tasks.create!(title: "Locked", item_type: "feature", board_state: "in_review",
                               pr_url: "https://github.com/x/y/pull/1", pr_number: 1, position: nil)
  post board_reorder_path(project), params: { order: [item.id] }
  assert_nil item.reload.position, "in_review item position is never stamped by reorder"
end
```

- [ ] Run → FAIL.
- [ ] Implement — in `BoardsController#reorder`, change the stamping loop:

```ruby
      ids.each_with_index do |id, i|
        @project.tasks.where(id: id).where.not(board_state: "in_review")
                .update_all(position: i + 1, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      end
```

- [ ] UI — in `app/views/boards/_group.html.erb`, make the in_review list non-sortable. Change the `<ul …>` so `data-sortable-list` is omitted for in_review:

```erb
  <ul <%= "data-sortable-list" unless state == "in_review" %> data-board-state="<%= state %>" class="divide-y divide-[color:var(--color-hair)] min-h-[8px]">
```

- [ ] Run → PASS. Commit.

---

## Final verification

- [ ] `bin/rails test test/models/task_test.rb test/integration/board_test.rb` → green.
- [ ] `bin/rubocop` on changed files → clean.

## Self-Review Notes
- **Spec coverage:** immutable `review_ready_at` (Task 1–2), ordering on /review + board + merge train (Tasks 2–3), reorder lock server + UI (Task 4).
- **Type consistency:** `review_ready_at` datetime; `awaiting_merge` and the review/board orderings all key on it ASC NULLS LAST.
