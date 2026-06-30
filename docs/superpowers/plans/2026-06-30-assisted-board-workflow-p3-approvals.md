# Assisted Board Workflow — Phase 3: /approvals inbox + landing blink

> REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Surface every parked item in one cross-project `/approvals` inbox, and pulse a project on the landing page when it needs the human.

**Architecture:** A `Task.awaiting_human` scope (waiting + wait_reason) drives both surfaces. `ApprovalsController#index` mirrors `ReviewsController`, grouped by project and split into Needs-input / Awaiting-approval, rendering the existing `boards/_approval_panel`. The projects index subscribes to a `:projects_overview` Turbo stream; a card pulses when `Project#needs_attention?`, and the model re-broadcasts the index when an item enters/leaves waiting.

**Spec:** `docs/superpowers/specs/2026-06-30-assisted-board-workflow-design.md`

---

## Task 1: `Task.awaiting_human` scope + `Project#needs_attention?`

**Files:** `app/models/task.rb`, `app/models/project.rb`; Test `test/models/task_test.rb`

- [ ] Test (task_test.rb):

```ruby
test "awaiting_human covers waiting items with a wait_reason" do
  a = @project.tasks.create!(title: "A", item_type: "feature", board_state: "waiting", wait_reason: "needs_input")
  b = @project.tasks.create!(title: "B", item_type: "feature", board_state: "waiting", wait_reason: "awaiting_approval")
  @project.tasks.create!(title: "C", item_type: "feature", board_state: "waiting") # parked, no reason
  @project.tasks.create!(title: "D", item_type: "feature", board_state: "pending")
  assert_equal [a.id, b.id].sort, @project.tasks.awaiting_human.pluck(:id).sort
  assert @project.needs_attention?
end
```

- [ ] Run `bin/rails test test/models/task_test.rb -n "/awaiting_human/"` → FAIL.
- [ ] Implement — Task scope (near `actionable`):

```ruby
  scope :awaiting_human, -> { where(board_state: "waiting").where.not(wait_reason: nil) }
```

Project (near `needs ...`):

```ruby
  # Any board item parked waiting on the human (needs input or plan approval).
  def needs_attention?
    tasks.awaiting_human.exists?
  end

  def attention_count
    tasks.awaiting_human.count
  end
```

- [ ] Run → PASS. Commit: `git add -A && git commit -m "feat(board): awaiting_human scope + Project#needs_attention?"`

---

## Task 2: `/approvals` inbox (controller, route, view, nav)

**Files:** Create `app/controllers/approvals_controller.rb`, `app/views/approvals/index.html.erb`; modify `config/routes.rb`, `app/helpers/ui_helper.rb`, `app/views/layouts/application.html.erb`; Test `test/integration/approvals_test.rb`

- [ ] Route — top-level (next to `get "review"`):

```ruby
  get "approvals", to: "approvals#index", as: :approvals
```

- [ ] Test first (`test/integration/approvals_test.rb`):

```ruby
require "test_helper"

class ApprovalsTest < ActionDispatch::IntegrationTest
  test "the inbox lists awaiting-approval and needs-input items, skipping archived projects" do
    project = Project.create!(name: "Inbox", slug: "inbox-#{SecureRandom.hex(3)}", repo_path: "/tmp/inbox")
    approve_item = project.tasks.create!(title: "Approve me", item_type: "feature", board_state: "waiting",
                                         wait_reason: "awaiting_approval", agent_role: "engineering", plan: "p")
    input_item = project.tasks.create!(title: "Answer me", item_type: "feature", board_state: "waiting",
                                       wait_reason: "needs_input",
                                       pending_questions: [{ "id" => "q1", "q" => "Which?", "a" => nil }])
    archived = Project.create!(name: "Old", slug: "old-#{SecureRandom.hex(3)}", repo_path: "/tmp/old",
                               archived_at: Time.current)
    archived.tasks.create!(title: "Hidden", item_type: "feature", board_state: "waiting",
                           wait_reason: "awaiting_approval", plan: "x")

    get approvals_path
    assert_response :success
    assert_match "Approve me", response.body
    assert_match "Answer me", response.body
    assert_no_match "Hidden", response.body
    assert_select "form[action=?]", board_item_approve_path(project, approve_item)
  end
end
```

- [ ] Run → FAIL.
- [ ] Implement controller `app/controllers/approvals_controller.rb`:

```ruby
# A single cross-project approvals inbox: every board item parked waiting on the
# human — split into "needs your input" (the agent asked questions) and "awaiting
# approval" (a plan is ready) — with the same answer / Approve / Request-changes
# controls the task page offers. The deep-link target for the blink + push.
class ApprovalsController < ApplicationController
  def index
    items = Task.awaiting_human
                .includes(:project)
                .joins(:project).where(projects: { archived_at: nil })
                .order("projects.name ASC", Arel.sql("tasks.updated_at ASC"))
    @needs_input        = items.select(&:needs_input?).group_by(&:project)
    @awaiting_approval  = items.select(&:awaiting_approval?).group_by(&:project)
  end
end
```

- [ ] Implement view `app/views/approvals/index.html.erb`:

```erb
<% content_for :title, "Approvals" %>

<div class="min-w-0">
  <div class="flex items-center gap-2 eyebrow">
    <%= link_to "clients", clients_path, class: "hover:text-[color:var(--color-ink)]" %>
    <span>/</span><span class="text-[color:var(--color-ink-soft)]">approvals</span>
  </div>
  <h1 class="font-display text-[44px] leading-[1.05] tracking-tight mt-1">Approvals</h1>
  <p class="text-[color:var(--color-ink-soft)] text-sm mt-0.5">Plans and questions waiting on you.</p>
</div>

<% sections = [["Needs your input", @needs_input], ["Awaiting approval", @awaiting_approval]] %>
<% if sections.all? { |_t, g| g.blank? } %>
  <div class="paper px-5 py-8 text-center mt-5">
    <p class="text-sm text-[color:var(--color-ink-soft)]">Nothing waiting on you.</p>
  </div>
<% else %>
  <% sections.each do |title, groups| %>
    <% next if groups.blank? %>
    <h2 class="mt-6 mb-2 text-xs font-semibold uppercase tracking-wider text-[color:var(--color-ink-soft)]"><%= title %></h2>
    <div class="space-y-4">
      <% groups.each do |project, items| %>
        <div class="paper p-4">
          <%= link_to project.name, board_path(project),
                class: "text-sm font-medium text-[color:var(--color-ink)] hover:text-[color:var(--color-amber-ink)]" %>
          <div class="mt-3 space-y-4">
            <% items.each do |item| %>
              <div class="hair-t pt-3">
                <%= link_to item.title, [project, item], class: "text-sm font-medium underline" %>
                <%= render "boards/approval_panel", project: project, task: item %>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
  <% end %>
<% end %>
```

- [ ] Helper `app/helpers/ui_helper.rb` (near `review_queue_count`):

```ruby
  def approvals_count
    @approvals_count ||= Task.awaiting_human.joins(:project)
                             .where(projects: { archived_at: nil }).count
  end
```

- [ ] Nav `app/views/layouts/application.html.erb` — after the Review-queue `<%= link_to review_path … end %>` block (before `</nav>`):

```erb
          <%# Cross-project approvals inbox — items parked waiting on the human %>
          <% approvals_active = controller_name == "approvals"
             appr_count = approvals_count %>
          <%= link_to approvals_path, class: "clink #{approvals_active ? 'clink-active' : ''}" do %>
            <span class="dot <%= appr_count.positive? ? 'dot-accent' : 'dot-idle' %>" role="img" aria-label="Items awaiting you: <%= appr_count %>" title="Items awaiting you: <%= appr_count %>"></span>
            <span class="truncate">Approvals</span>
            <% if appr_count.positive? %>
              <span class="ml-auto text-[10.5px] tabular font-mono text-[color:var(--color-amber-ink)]"><%= appr_count %></span>
            <% else %>
              <span class="clink-slug truncate max-w-[90px]">inbox</span>
            <% end %>
          <% end %>
```

> If the `dot-accent` class doesn't exist, use `dot-pass`. Verify the existing dot classes in `app/assets`/Tailwind; pick one that renders.

- [ ] Run the integration test → PASS.
- [ ] Commit: `git add -A && git commit -m "feat(board): cross-project /approvals inbox + nav entry"`

---

## Task 3: Landing-page blink

**Files:** Modify `app/views/projects/index.html.erb` (extract card → `app/views/projects/_card.html.erb`), `app/models/task.rb`; Test `test/integration/projects_blink_test.rb`

- [ ] Test first (`test/integration/projects_blink_test.rb`):

```ruby
require "test_helper"

class ProjectsBlinkTest < ActionDispatch::IntegrationTest
  test "a project needing attention pulses with a needs-you badge on the index" do
    project = Project.create!(name: "Blinky", slug: "blinky-#{SecureRandom.hex(3)}", repo_path: "/tmp/blinky")
    project.tasks.create!(title: "Approve me", item_type: "feature", board_state: "waiting",
                          wait_reason: "awaiting_approval", plan: "p")
    get projects_path
    assert_response :success
    assert_select "#project_card_#{project.id}"
    assert_match "Needs you", response.body
  end
end
```

- [ ] Run → FAIL.
- [ ] Implement — in `app/views/projects/index.html.erb`:
  - Add a subscription right after the `content_for :title` line: `<%= turbo_stream_from :projects_overview %>`.
  - Replace the inner project-card `<div>…</div>` (the whole `group relative rounded-xl …` block) with: `<%= render "card", project: project %>`.
- [ ] Create `app/views/projects/_card.html.erb` with the moved markup, wrapping the outer div with an id and pulse:

```erb
<div id="project_card_<%= project.id %>"
     class="group relative rounded-xl border bg-[color:var(--color-paper-raised)] p-4 shadow-sm hover:shadow-md transition <%= project.needs_attention? ? 'border-[color:var(--color-amber-ink)] ring-1 ring-[color:var(--color-amber-ink)] animate-pulse' : 'border-[color:var(--color-hair)]' %> <%= 'opacity-75' if project.archived? %>">
  <%= link_to project, class: "absolute inset-0 rounded-xl", aria: { label: project.name } do %><% end %>
  <div class="flex items-center justify-between gap-2">
    <h3 class="font-semibold text-[color:var(--color-ink)] group-hover:text-[color:var(--color-ink-soft)] truncate"><%= project.name %></h3>
    <span class="text-xs font-mono text-[color:var(--color-ink-faint)] shrink-0 <%= "group-hover:opacity-0 transition-opacity" unless project.archived? %>"><%= project.slug %></span>
  </div>
  <% if project.needs_attention? %>
    <div class="mt-1 inline-flex items-center gap-1 rounded-full bg-[color:var(--color-amber-wash)] px-2 py-0.5 text-[10px] font-medium text-[color:var(--color-amber-ink)] relative z-10">
      Needs you · <%= project.attention_count %>
    </div>
  <% end %>
  <p class="mt-2 text-sm text-[color:var(--color-ink-soft)] line-clamp-2"><%= project.description.presence || "No description." %></p>
  <% r = project.rollup %>
  <div class="mt-4 grid grid-cols-4 gap-2 text-center">
    <div><div class="text-lg font-semibold text-[color:var(--color-ink)]"><%= r[:tasks] %></div><div class="text-[11px] uppercase tracking-wide text-[color:var(--color-ink-faint)]">tasks</div></div>
    <div><div class="text-lg font-semibold text-[color:var(--color-amber-ink)]"><%= r[:open_tasks] %></div><div class="text-[11px] uppercase tracking-wide text-[color:var(--color-ink-faint)]">open</div></div>
    <div><div class="text-lg font-semibold text-[color:var(--color-ink)]"><%= r[:test_plans] %></div><div class="text-[11px] uppercase tracking-wide text-[color:var(--color-ink-faint)]">plans</div></div>
    <div><div class="text-lg font-semibold text-[color:var(--color-fail-ink)]"><%= r[:open_follow_ups] %></div><div class="text-[11px] uppercase tracking-wide text-[color:var(--color-ink-faint)]">gaps</div></div>
  </div>
  <% if project.archived? %>
    <%= button_to unarchive_project_path(project), method: :patch,
          form_class: "absolute top-3 right-3 z-10",
          class: "inline-flex items-center gap-1 rounded-md border border-[color:var(--color-hair)] bg-[color:var(--color-paper-raised)] px-2 py-1 text-[11px] font-medium text-[color:var(--color-ink-soft)] hover:text-[color:var(--color-ink)] shadow-sm cursor-pointer",
          title: "Unarchive #{project.name}" do %>Unarchive<% end %>
  <% else %>
    <%= button_to archive_project_path(project), method: :patch,
          form_class: "absolute top-3 right-3 z-10 opacity-0 group-hover:opacity-100 focus-within:opacity-100 transition-opacity",
          class: "inline-flex items-center gap-1 rounded-md border border-[color:var(--color-hair)] bg-[color:var(--color-paper-raised)] px-2 py-1 text-[11px] font-medium text-[color:var(--color-ink-soft)] hover:text-[color:var(--color-ink)] shadow-sm cursor-pointer",
          title: "Archive #{project.name}" do %>Archive<% end %>
  <% end %>
</div>
```

- [ ] Broadcast on waiting changes — in `app/models/task.rb`, add a callback so the index re-renders live:

```ruby
  after_update_commit :broadcast_projects_overview,
                      if: -> { saved_change_to_wait_reason? || saved_change_to_board_state? }
```

private:

```ruby
  def broadcast_projects_overview
    Turbo::StreamsChannel.broadcast_refresh_to(:projects_overview)
  rescue StandardError => e
    Rails.logger.warn("[board] overview broadcast failed: #{e.message}")
  end
```

- [ ] Run the blink test → PASS.
- [ ] Commit: `git add -A && git commit -m "feat(board): landing-page blink for projects needing attention"`

---

## Final verification

- [ ] `bin/rails test test/models/task_test.rb test/integration/approvals_test.rb test/integration/projects_blink_test.rb test/integration/board_test.rb` → green.
- [ ] `bin/rubocop` on changed Ruby files → clean.
- [ ] Rebuild Tailwind so the new classes (`animate-pulse`, amber ring) render: `docker compose exec pyr-myjira bin/rails tailwindcss:build` (or the project's build task) — note in the report if the watcher is live.

## Self-Review Notes
- **Spec coverage:** `/approvals` inbox (Task 2), landing blink (Task 3), both fed by `awaiting_human` (Task 1). Reuses `boards/_approval_panel` so Approve/answer/request-changes behave identically to the task page.
- **Type consistency:** `awaiting_human` scope, `needs_attention?`/`attention_count` on Project, `approvals_count` helper. Card dom id `project_card_<id>`.
- **Deferred:** true Web Push is Phase 4.
