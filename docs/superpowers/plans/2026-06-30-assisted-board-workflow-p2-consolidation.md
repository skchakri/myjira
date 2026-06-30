# Assisted Board Workflow — Phase 2: Consolidation (auto-merge) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans / subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** When a new pending item is created, automatically fold related still-pending items into one consolidated task — reversibly and auditably.

**Architecture:** A `Board::Consolidator` module called from the existing `InstantTriageJob` (which already runs Haiku per new pending item). It shortlists other `pending`, unmerged items in the same project, asks Haiku which represent the same work, then merges them into the oldest as primary: secondaries get `merged_into_id` set (dropping off the board) and their content appended to the primary's description. An **Unmerge** action restores a secondary to pending.

**Tech Stack:** Rails 8, PostgreSQL, `Anthropic::MessagesClient` (Haiku), Minitest + `StubSupport`.

**Spec:** `docs/superpowers/specs/2026-06-30-assisted-board-workflow-design.md`

---

## Task 1: Migration — `merged_into_id`

**Files:** Create `db/migrate/20260630000002_add_merged_into_to_tasks.rb`

- [ ] Write:

```ruby
class AddMergedIntoToTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :tasks, :merged_into_id, :uuid
    add_index  :tasks, :merged_into_id
  end
end
```

- [ ] `bin/rails db:migrate` — expect schema shows `merged_into_id`.
- [ ] Commit: `git add -A && git commit -m "feat(board): add merged_into_id to tasks"`

---

## Task 2: Model — associations, scope, board/queue exclusion

**Files:** Modify `app/models/task.rb`, `app/models/project.rb`; Test `test/models/task_test.rb`

- [ ] **Test first** (task_test.rb):

```ruby
test "merged items are excluded from the actionable queue and report merged?" do
  primary = @project.tasks.create!(title: "Primary", item_type: "feature", board_state: "pending")
  child   = @project.tasks.create!(title: "Child", item_type: "feature", board_state: "pending",
                                   merged_into_id: primary.id)
  assert child.merged?
  assert_not primary.merged?
  ids = @project.tasks.actionable.pluck(:id)
  assert_includes ids, primary.id
  assert_not_includes ids, child.id, "merged child is not actionable"
  assert_equal [child.id], primary.merged_children.pluck(:id)
end
```

- [ ] Run: `bin/rails test test/models/task_test.rb -n "/merged items are excluded/"` → FAIL.

- [ ] **Implement** in `app/models/task.rb`:

Associations (near the other `belongs_to`, after `belongs_to :last_test_run …`):

```ruby
  belongs_to :merged_into, class_name: "Task", optional: true
  has_many :merged_children, class_name: "Task", foreign_key: :merged_into_id, dependent: :nullify
```

Scope + exclude merged from `actionable` (replace the existing `actionable` scope line):

```ruby
  scope :unmerged, -> { where(merged_into_id: nil) }
  scope :actionable, -> { where(board_state: ACTIONABLE_STATES, merged_into_id: nil) }
```

Predicate (near `done?`):

```ruby
  def merged?
    merged_into_id.present?
  end
```

In `app/models/project.rb`, exclude merged items from the board display — replace `board_items`:

```ruby
  def board_items
    tasks.unmerged.with_attached_attachments.board_ordered
  end
```

- [ ] Run the test → PASS. Also run full `task_test.rb` to confirm no regression.
- [ ] Commit: `git add -A && git commit -m "feat(board): merged_into associations, unmerged scope, board/queue exclusion"`

---

## Task 3: `Board::Consolidator` service

**Files:** Create `app/services/board/consolidator.rb`; Test `test/services/board/consolidator_test.rb`

- [ ] **Test first** (`test/services/board/consolidator_test.rb`):

```ruby
require "test_helper"

class Board::ConsolidatorTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "C", slug: "c-#{SecureRandom.hex(3)}", repo_path: "/tmp/c")
  end

  test "merge! folds the group into the oldest as primary and appends content" do
    older = @project.tasks.create!(title: "Add export", item_type: "feature", board_state: "pending",
                                   description: "Original", created_at: 2.hours.ago)
    newer = @project.tasks.create!(title: "CSV export too", item_type: "feature", board_state: "pending",
                                   description: "Also CSV")
    primary = Board::Consolidator.merge!([newer, older])
    assert_equal older.id, primary.id, "oldest is primary"
    newer.reload
    assert_equal older.id, newer.merged_into_id
    assert_match "Merged sub-items", older.reload.description
    assert_match "CSV export too", older.description
  end

  test "run! merges items the detector flags as related" do
    a = @project.tasks.create!(title: "Dark mode", item_type: "feature", board_state: "pending",
                               created_at: 1.hour.ago)
    b = @project.tasks.create!(title: "Night theme", item_type: "feature", board_state: "pending")
    Board::Consolidator.stub(:detect_related, ->(_task, cands) { cands.map(&:id) }) do
      Board::Consolidator.run!(b)
    end
    assert_equal a.id, b.reload.merged_into_id
  end

  test "run! is a no-op when the detector finds nothing related" do
    @project.tasks.create!(title: "Unrelated A", item_type: "feature", board_state: "pending")
    b = @project.tasks.create!(title: "Unrelated B", item_type: "feature", board_state: "pending")
    Board::Consolidator.stub(:detect_related, ->(_task, _cands) { [] }) do
      Board::Consolidator.run!(b)
    end
    assert_nil b.reload.merged_into_id
  end

  test "run! ignores non-pending candidates" do
    @project.tasks.create!(title: "In flight", item_type: "feature", board_state: "in_progress")
    b = @project.tasks.create!(title: "New", item_type: "feature", board_state: "pending")
    captured = nil
    Board::Consolidator.stub(:detect_related, ->(_t, cands) { captured = cands; [] }) do
      Board::Consolidator.run!(b)
    end
    assert_equal [], captured, "only pending unmerged candidates are considered"
  end
end
```

- [ ] Run → FAIL (no Consolidator).

- [ ] **Implement** `app/services/board/consolidator.rb`:

```ruby
require "json"

# Auto-merges related still-pending board items into one. Called from
# InstantTriageJob after a new pending item is triaged. Detection is a cheap Haiku
# call (stubbed in tests); merging folds the group into the OLDEST item as primary,
# appends each secondary's content to the primary, and sets merged_into_id on the
# secondaries so they drop off the board. Reversible via Task#unmerge (Unmerge UI).
module Board
  module Consolidator
    module_function

    MODEL      = "claude-haiku-4-5-20251001".freeze
    MAX_TOKENS = 128

    SYSTEM_PROMPT = <<~SYS.strip
      You decide which existing backlog items describe the SAME work as a new item.
      Reply with ONLY valid JSON: {"duplicates":[<1-based indices of the same work>]}.
      Be conservative — include an index only if it is clearly the same task, not
      merely related. Empty list if none.
    SYS

    # Entry point. Merges `task` with any pending siblings the detector flags.
    def run!(task)
      return unless task&.board_state == "pending" && task.merged_into_id.nil?
      candidates = task.project.tasks
                       .where(board_state: "pending", merged_into_id: nil)
                       .where.not(id: task.id).order(:created_at).to_a
      return if candidates.empty?

      related_ids = Array(detect_related(task, candidates)).map(&:to_s)
      group = [task] + candidates.select { |c| related_ids.include?(c.id.to_s) }
      return if group.size < 2

      merge!(group)
    end

    # Fold a group into the oldest item. Returns the primary.
    def merge!(group)
      group = group.uniq
      primary = group.min_by(&:created_at)
      secondaries = group - [primary]
      return primary if secondaries.empty?

      Task.transaction do
        appended = secondaries.map do |s|
          s.update!(merged_into_id: primary.id)
          "- **#{s.title}**#{s.description.present? ? "\n  #{s.description.to_s.truncate(500)}" : ''}"
        end
        merged_block = "\n\n## Merged sub-items\n#{appended.join("\n")}"
        primary.update!(description: "#{primary.description}#{merged_block}".strip)
      end
      primary.emit_worklog("board.consolidated", status: "info",
        label: "Merged #{secondaries.size} related item(s)",
        payload: { merged_ids: secondaries.map(&:id) })
      primary
    end

    # Haiku: which candidates are the same work as `task`? Returns an array of ids.
    def detect_related(task, candidates)
      api_key = ENV["ANTHROPIC_API_KEY"].to_s.strip
      return [] if api_key.blank?

      listing = candidates.each_with_index.map do |c, i|
        "#{i + 1}. #{c.title}#{c.description.present? ? " — #{c.description.to_s.truncate(160)}" : ''}"
      end.join("\n")
      user = "New item:\n#{task.title}#{task.description.present? ? " — #{task.description.to_s.truncate(300)}" : ''}\n\n" \
             "Existing pending items:\n#{listing}"

      client = Anthropic::MessagesClient.new(api_key: api_key)
      raw = client.complete(model: MODEL, max_tokens: MAX_TOKENS, system: SYSTEM_PROMPT, user: user)
      text = raw.to_s.strip.sub(/\A```(?:json)?\s*/i, "").sub(/```\s*\z/, "")
      idx = Array(JSON.parse(text)["duplicates"]).map(&:to_i)
      idx.filter_map { |n| candidates[n - 1]&.id if n.positive? }
    rescue Anthropic::Error, JSON::ParserError => e
      Rails.logger.warn("[consolidator] #{task.id}: #{e.class}: #{e.message}")
      []
    end
  end
end
```

- [ ] Run the test → PASS.
- [ ] Commit: `git add -A && git commit -m "feat(board): Board::Consolidator auto-merge service"`

---

## Task 4: Hook into `InstantTriageJob`

**Files:** Modify `app/jobs/instant_triage_job.rb`; Test `test/jobs/instant_triage_job_test.rb` (create if absent)

- [ ] **Test first** — verify the job calls the consolidator:

```ruby
require "test_helper"

class InstantTriageJobConsolidationTest < ActiveSupport::TestCase
  setup { @project = Project.create!(name: "J", slug: "j-#{SecureRandom.hex(3)}", repo_path: "/tmp/j") }

  test "perform runs the consolidator for a pending item" do
    task = @project.tasks.create!(title: "X", item_type: "feature", board_state: "pending")
    called = nil
    Board::Consolidator.stub(:run!, ->(t) { called = t.id }) do
      InstantTriageJob.new.perform(task.id)
    end
    assert_equal task.id, called
  end
end
```

- [ ] Run → FAIL.

- [ ] **Implement**: in `app/jobs/instant_triage_job.rb#perform`, after the triage suggestion is stored/applied (end of the method body, before the `rescue`), add:

```ruby
    # After triage, fold any related pending items into one (reversible).
    Board::Consolidator.run!(task.reload) if task.board_state == "pending"
```

- [ ] Run → PASS.
- [ ] Commit: `git add -A && git commit -m "feat(board): run consolidator after instant triage"`

---

## Task 5: Unmerge — route + controller action

**Files:** Modify `config/routes.rb`, `app/controllers/boards_controller.rb`; Test `test/integration/board_test.rb`

- [ ] **Route** (next to the other `board/items/:id/*`):

```ruby
    post  "board/items/:id/unmerge", to: "boards#unmerge", as: :board_item_unmerge
```

- [ ] **Test first** (board_test.rb):

```ruby
test "unmerge restores a merged child to the board" do
  project = Project.create!(name: "Um", slug: "um-#{SecureRandom.hex(3)}", repo_path: "/tmp/um")
  primary = project.tasks.create!(title: "Primary", item_type: "feature", board_state: "pending")
  child = project.tasks.create!(title: "Child", item_type: "feature", board_state: "pending",
                                merged_into_id: primary.id)
  post board_item_unmerge_path(project, child)
  assert_nil child.reload.merged_into_id
end
```

- [ ] Run → FAIL.

- [ ] **Implement**: add `:unmerge` to the `set_task` before_action list, and the action (after `answer_questions`):

```ruby
  # Reverse a consolidation: detach this item from its primary so it returns to the
  # board as its own pending item.
  def unmerge
    @task.update!(merged_into_id: nil)
    redirect_back fallback_location: [@project, @task], notice: "Unmerged — back on the board."
  end
```

- [ ] Run → PASS.
- [ ] Commit: `git add -A && git commit -m "feat(board): unmerge action + route"`

---

## Task 6: View — merged sub-items + unmerge on the task page

**Files:** Modify `app/views/tasks/show.html.erb`; Test `test/integration/board_test.rb`

- [ ] **Test first**:

```ruby
test "the primary task page lists merged children with an unmerge control" do
  project = Project.create!(name: "Mv", slug: "mv-#{SecureRandom.hex(3)}", repo_path: "/tmp/mv")
  primary = project.tasks.create!(title: "Primary", item_type: "feature", board_state: "pending")
  child = project.tasks.create!(title: "Folded child", item_type: "feature", board_state: "pending",
                                merged_into_id: primary.id)
  get project_task_path(project, primary)
  assert_response :success
  assert_match "Folded child", response.body
  assert_select "form[action=?]", board_item_unmerge_path(project, child)
end
```

- [ ] Run → FAIL.

- [ ] **Implement**: in `app/views/tasks/show.html.erb`, after the approval-panel render line, add:

```erb
    <% if @task.merged_children.any? %>
      <%= card title: "Merged sub-items" do %>
        <ul class="space-y-2">
          <% @task.merged_children.each do |child| %>
            <li class="flex items-center justify-between gap-2">
              <span class="text-sm text-[color:var(--color-ink)]"><%= child.title %></span>
              <%= button_to "Unmerge", board_item_unmerge_path(@project, child), method: :post,
                    class: "text-xs border border-[color:var(--color-hair)] px-2 py-1 rounded text-[color:var(--color-ink-soft)] cursor-pointer" %>
            </li>
          <% end %>
        </ul>
      <% end %>
    <% end %>
    <% if @task.merged? %>
      <div class="mb-4 text-sm text-[color:var(--color-ink-soft)]">
        Merged into <%= link_to @task.merged_into.title, [@project, @task.merged_into], class: "underline" %>.
        <%= button_to "Unmerge", board_item_unmerge_path(@project, @task), method: :post,
              class: "ml-2 text-xs underline cursor-pointer bg-transparent border-0 text-[color:var(--color-amber-ink)]" %>
      </div>
    <% end %>
```

- [ ] Run → PASS.
- [ ] Commit: `git add -A && git commit -m "feat(board): merged sub-items + unmerge UI on the task page"`

---

## Final verification

- [ ] `bin/rails test test/models/task_test.rb test/services/board/consolidator_test.rb test/jobs/instant_triage_job_test.rb test/integration/board_test.rb` → all green.
- [ ] `bin/rubocop app/services/board/consolidator.rb app/models/task.rb app/models/project.rb app/jobs/instant_triage_job.rb app/controllers/boards_controller.rb` → no offenses.

## Self-Review Notes
- **Spec coverage:** auto-merge of related pending (Tasks 3–4), reversible Unmerge (Tasks 5–6), board/queue exclusion (Task 2). Triage/consolidation runs server-side on item metadata (execution-boundary respected). Detection is conservative (precision over recall) per the spec's open question.
- **Type consistency:** `merged_into_id` is the FK everywhere; `detect_related` returns task ids; `merge!` takes an array of Task records and returns the primary.
