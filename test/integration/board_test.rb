require "test_helper"

# End-to-end board behaviour: rendering, inline edits, drag-reorder, modals,
# the manual pipeline pick-up, and autopilot controls.
class BoardTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Board Test", slug: "board-test-#{SecureRandom.hex(3)}",
                               repo_path: "/tmp/board-test")
    @a = @project.tasks.create!(title: "Issue A", item_type: "issue", board_state: "pending")
    @b = @project.tasks.create!(title: "Feature B", item_type: "feature", board_state: "planned",
                                agent_role: "engineering")
  end

  test "projects are categorized by repo path" do
    assert_equal "pyr", Project.category_for("/home/kalyan/platform/clients/monat/pyr")
    assert_equal "icentris", Project.category_for("/home/kalyan/platform/icentris/etl")
    assert_equal "skchakri", Project.category_for("/home/kalyan/platform/skchakri/ownsites")
    assert_equal "skchakri", Project.category_for("/home/kalyan/pyr-docker")
    assert_equal "other", Project.category_for("/home/kalyan/Downloads")
    p = Project.create!(name: "Cat", slug: "cat-#{SecureRandom.hex(3)}",
                        repo_path: "/home/kalyan/platform/clients/foo/pyr")
    assert_equal "pyr", p.category, "category is auto-assigned on create"
  end

  test "gap importer moves open follow-ups onto the board" do
    fu = @project.follow_up_tasks.create!(title: "Login throws 500 on SSO", kind: "bug",
                                          severity: "high", status: "open")
    res = Board::GapImporter.import(@project)
    assert_equal 1, res[:created]
    item = @project.tasks.find_by(title: "Login throws 500 on SSO")
    assert_equal "issue", item.item_type
    assert_equal "high", item.priority
    assert_equal "pending", item.board_state
    assert_equal "resolved", fu.reload.status, "moved gap is resolved off the open list"
    assert_equal item.id, fu.task_id, "gap links to its board item"
  end

  test "table board renders with its items" do
    get board_path(@project)
    assert_response :success
    assert_select "[data-controller='sortable']"
    assert_match @a.title, response.body
    assert_match @b.title, response.body
  end

  test "kanban view renders sortable lists" do
    get board_path(@project, view: "kanban")
    assert_response :success
    assert_select "[data-sortable-list]"
  end

  test "create_item appends a pending item at the bottom of the queue" do
    assert_difference -> { @project.tasks.count }, 1 do
      post board_items_path(@project), params: { task: { title: "New ask", item_type: "ask", priority: "high" } }
    end
    item = @project.tasks.order(:position).last
    assert_equal "New ask", item.title
    assert_equal "ask", item.item_type
    assert_equal "pending", item.board_state
    assert item.position > @b.position
  end

  test "create_item attaches uploaded context files to the new item" do
    file = fixture_file_upload("context-note.txt", "text/plain")
    assert_difference -> { @project.tasks.count }, 1 do
      post board_items_path(@project),
           params: { task: { title: "With context", description: "see attached", attachments: [file] } }
    end
    item = @project.tasks.find_by!(title: "With context")
    assert item.attachments.attached?
    assert_equal 1, item.attachments.size
    assert_equal "context-note.txt", item.attachments.first.filename.to_s

    # The board row shows an attachment indicator…
    get board_path(@project)
    assert_select "li[data-id='#{item.id}']", text: /📎/
    # …and the item page renders the gallery.
    get project_task_path(@project, item)
    assert_match "Attachments", response.body
    assert_match "context-note.txt", response.body
  end

  test "create_item with a blank title derives a placeholder and queues a triage agent" do
    assert_difference -> { @project.tasks.count } => 1,
                      -> { SessionLaunch.where(pipeline_step: "triage").count } => 1 do
      post board_items_path(@project),
           params: { task: { title: "", item_type: "task",
                             description: "Client emailed: checkout throws a 500 when the coupon is expired. Urgent." } }
    end
    item = @project.tasks.order(:created_at).last
    assert_equal "pending", item.board_state
    assert item.title.present?, "a placeholder title is derived from the dumped context"
    assert_match(/checkout/i, item.title)
    launch = SessionLaunch.where(pipeline_step: "triage").last
    assert_equal item.id, launch.task_id
    assert_includes launch.prompt, "/board-triage #{item.id}"
  end

  test "create_item with an explicit title skips triage" do
    assert_no_difference -> { SessionLaunch.where(pipeline_step: "triage").count } do
      post board_items_path(@project), params: { task: { title: "Explicit title", description: "some context" } }
    end
    assert_equal "Explicit title", @project.tasks.order(:created_at).last.title
  end

  test "create_item with a blank title and no context does not queue triage" do
    assert_no_difference -> { SessionLaunch.where(pipeline_step: "triage").count } do
      post board_items_path(@project), params: { task: { title: "", description: "" } }
    end
    assert_equal "Untitled item", @project.tasks.order(:created_at).last.title
  end

  test "api exposes attachment urls so the triage agent can read images" do
    @a.attachments.attach(io: StringIO.new("png-bytes"), filename: "shot.png", content_type: "image/png")
    get "/api/v1/projects/#{@project.slug}/tasks/#{@a.id}"
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["attachments"].size
    att = body["attachments"].first
    assert_equal "shot.png", att["filename"]
    assert_equal "image/png", att["content_type"]
    assert_match %r{/rails/active_storage/}, att["url"]
  end

  test "update_item changes board_state inline (204 + persisted)" do
    patch board_item_path(@project, @a), params: { task: { board_state: "hold" } }
    assert_response :no_content
    assert_equal "hold", @a.reload.board_state
  end

  test "reorder persists new positions and a moved item's new state" do
    post board_reorder_path(@project), params: { order: [@b.id, @a.id], moved_id: @a.id, moved_state: "in_progress" }
    assert_response :ok
    assert_equal 1, @b.reload.position
    assert_equal 2, @a.reload.position
    assert_equal "in_progress", @a.board_state
  end

  test "plan and pr modals render content" do
    @b.update!(plan: "## Step 1\nDo it", pr_url: "https://github.com/x/y/pull/1",
               pr_number: 1, pr_state: "open", pr_diff: "+ added line")
    get board_item_plan_path(@project, @b)
    assert_response :success
    assert_match "Step 1", response.body

    get board_item_pr_path(@project, @b)
    assert_response :success
    assert_match "Open on GitHub", response.body
    assert_match "added line", response.body
  end

  test "pick_up on a planned engineering item queues an engineering launch" do
    assert_difference -> { SessionLaunch.where(pipeline_step: "engineering").count }, 1 do
      post board_item_pick_up_path(@project, @b)
    end
    assert_redirected_to board_path(@project)
    launch = SessionLaunch.where(pipeline_step: "engineering").last
    assert_equal @b.id, launch.task_id
    assert_not_nil @b.reload.last_conversation_id, "pick_up should link the item to its session"
  end

  test "pick_up on a pending item queues a planning launch" do
    assert_difference -> { SessionLaunch.where(pipeline_step: "planning").count }, 1 do
      post board_item_pick_up_path(@project, @a)
    end
  end

  test "autopilot controls persist" do
    patch board_autopilot_path(@project), params: { project: { autopilot_enabled: "1", autopilot_daily_cap: "5" } }
    assert_response :no_content
    @project.reload
    assert @project.autopilot_enabled?
    assert_equal 5, @project.autopilot_daily_cap
  end

  test "global stop and resume flip the kill switch" do
    post autopilot_stop_all_path
    assert Setting.autopilot_stopped?
    post autopilot_resume_all_path
    assert_not Setting.autopilot_stopped?
  end

  test "run_tests without a plan redirects with an alert" do
    post board_item_run_tests_path(@project, @b)
    assert_redirected_to board_path(@project)
  end

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

  test "pr modal shows approve and reject for an in_review item with a PR" do
    @b.update!(board_state: "in_review", pr_url: "https://github.com/x/y/pull/9",
               pr_number: 9, pr_state: "open", pr_diff: "+ x")
    get board_item_pr_path(@project, @b)
    assert_response :success
    assert_select "form[action=?]", board_item_merge_path(@project, @b)
    assert_select "form[action=?]", board_item_reject_path(@project, @b)
    assert_select "input[name=reason]"
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

  test "board row shows a reject button for an in_review item with a PR" do
    @b.update!(board_state: "in_review", pr_url: "https://github.com/x/y/pull/5",
               pr_number: 5, pr_state: "open")
    get board_path(@project)
    assert_response :success
    assert_select "li[data-id='#{@b.id}'] form[action=?]", board_item_reject_path(@project, @b)
    assert_select "li[data-id='#{@b.id}'] form[action=?]", board_item_merge_path(@project, @b)
  end

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
end
