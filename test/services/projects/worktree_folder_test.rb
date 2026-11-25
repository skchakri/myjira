require "test_helper"

# Agent worktrees map to their parent repo's project, and the leftover worktree
# projects fold into it.
class Projects::WorktreeFolderTest < ActionDispatch::IntegrationTest
  setup do
    @tag = SecureRandom.hex(3)
    @repo = "/tmp/fold-#{@tag}/shop"
    @parent = Project.create!(name: "Shop #{@tag}", slug: "shop-#{@tag}", repo_path: @repo)
    @inside = leftover("agent-a1", "#{@repo}/.claude/worktrees/agent-a1")
    @sibling = leftover("shop-wq-7", "#{@repo}-wq-7")
  end

  # A project saved on a worktree path before the model resolved such paths on save.
  def leftover(name, path)
    Project.create!(name: name, slug: "#{name}-#{@tag}").tap { |p| p.update_column(:repo_path, path) }
  end

  def fold(dry_run: false, out: StringIO.new)
    [Projects::WorktreeFolder.new(dry_run: dry_run, out: out).call, out.string]
  end

  def ours(result) = result.folds.select { |f| f.parent == @parent }

  # --- resolver -------------------------------------------------------------

  test "a worktree inside the repo resolves to the repo" do
    assert_equal @repo, Project.canonical_repo_path("#{@repo}/.claude/worktrees/agent-a1")
    assert_equal @repo, Project.canonical_repo_path("#{@repo}/.claude/worktrees/os-034/app/models/")
  end

  test "a -wq-N sibling resolves only when its parent is a known repo" do
    assert_equal @repo, Project.canonical_repo_path("#{@repo}-wq-12")
    assert_equal "/tmp/nobody-#{@tag}-wq-3", Project.canonical_repo_path("/tmp/nobody-#{@tag}-wq-3")
  end

  test "a worktree of a wq worktree resolves all the way to the repo" do
    assert_equal @repo, Project.canonical_repo_path("#{@repo}-wq-7/.claude/worktrees/agent-b2")
  end

  test "saving a project on a worktree path saves the repo it is a checkout of" do
    typed = Project.create!(name: "typed #{@tag}", slug: "typed-#{@tag}", repo_path: "#{@repo}/.claude/worktrees/agent-a1/")
    assert_equal @repo, typed.repo_path

    typed.update!(repo_path: "#{@repo}-wq-12")
    assert_equal @repo, typed.repo_path
    typed.update!(repo_path: "/tmp/nobody-#{@tag}-wq-3")
    assert_equal "/tmp/nobody-#{@tag}-wq-3", typed.repo_path, "a -wq-N name with no known parent is a repo of its own"
    typed.update!(repo_path: "")
    assert_equal "", typed.repo_path
  end

  test "a project already on a worktree path keeps it until the path itself is edited" do
    @inside.update!(description: "still here")
    assert_equal "#{@repo}/.claude/worktrees/agent-a1", @inside.reload.repo_path
  end

  test "the web form saves a typed worktree path as the parent repo" do
    patch project_path(@inside), params: { project: { repo_path: "#{@repo}-wq-7/app" } }
    assert_equal @repo, @inside.reload.repo_path
  end

  test "plain repos and blanks are left alone" do
    assert_equal @repo, Project.canonical_repo_path("#{@repo}/")
    assert_nil Project.canonical_repo_path(nil)
    assert_not Project.worktree_path?(@repo)
    assert Project.worktree_path?("#{@repo}-wq-7")
    assert @inside.worktree?
    assert_not @parent.worktree?
  end

  test "for_repo_path finds the parent, never the worktree's own project" do
    assert_equal @parent, Project.for_repo_path("#{@repo}/.claude/worktrees/agent-a1")
    assert_equal @parent, Project.for_repo_path("#{@repo}-wq-7")
  end

  # --- capture --------------------------------------------------------------

  test "a session captured from a new worktree lands on the parent and creates no project" do
    assert_no_difference "Project.count" do
      post sync_api_v1_conversations_path, as: :json, params: {
        project: { slug: "agent-zz-#{@tag}", name: "agent-zz", repo_path: "#{@repo}/.claude/worktrees/agent-zz" },
        conversation: { session_id: "sess-#{@tag}", cwd: "#{@repo}/.claude/worktrees/agent-zz", source: "claude-cli" },
        messages: [{ ext_id: SecureRandom.uuid, role: "user", kind: "message", body: "hi" }]
      }
    end
    assert_response :success
    assert_equal @parent, Conversation.find_by!(session_id: "sess-#{@tag}").project
    assert_equal @repo, @parent.reload.repo_path
  end

  test "the first session of an unknown repo, seen from a worktree, creates the repo's project" do
    repo = "/tmp/fold-#{@tag}/fresh"
    post sync_api_v1_conversations_path, as: :json, params: {
      project: { slug: "agent-q-#{@tag}", name: "agent-q", repo_path: "#{repo}/.claude/worktrees/agent-q" },
      conversation: { session_id: "fresh-#{@tag}", cwd: repo, source: "claude-cli" },
      messages: [{ ext_id: SecureRandom.uuid, role: "user", kind: "message", body: "hi" }]
    }
    assert_response :success
    project = Conversation.find_by!(session_id: "fresh-#{@tag}").project
    assert_equal repo, project.repo_path
    assert_equal "fresh", project.name
  end

  test "a project upsert from inside a worktree returns the parent" do
    assert_no_difference "Project.count" do
      post "/api/v1/projects", as: :json,
                               params: { project: { slug: "shop-wq-9-#{@tag}", name: "shop-wq-9", repo_path: "#{@repo}-wq-9" } }
    end
    assert_response :ok
    assert_equal @parent.slug, response.parsed_body["slug"]
    assert_equal "Shop #{@tag}", @parent.reload.name
  end

  test "a document filed from inside a wq worktree goes to the parent" do
    post "/api/v1/documents", as: :json, params: { repo_path: "#{@repo}-wq-7/app", document: { title: "Plan #{@tag}", kind: "plan", body: "x" } }
    assert_response :created
    assert_equal @parent, Document.find_by!(title: "Plan #{@tag}").project
  end

  # --- fold -----------------------------------------------------------------

  test "dry run reports and changes nothing" do
    Conversation.create!(project: @inside, session_id: "c-#{@tag}")
    result, text = fold(dry_run: true)
    assert_equal [@inside, @sibling].sort_by(&:id), ours(result).map(&:project).sort_by(&:id)
    assert_match(/DRY RUN/, text)
    assert_match(/#{@inside.slug}\s+.*conversations=1/, text)
    assert_equal @inside, Conversation.find_by!(session_id: "c-#{@tag}").project
    assert_nil @inside.reload.archived_at
  end

  test "fold moves rows to the parent and archives the worktree project" do
    convo = Conversation.create!(project: @inside, session_id: "c-#{@tag}")
    task = Task.create!(project: @sibling, title: "Fix it")
    doc = Document.create!(project: @sibling, title: "Notes #{@tag}", kind: "note", body: "x")
    extra_env = @inside.environments.create!(name: "QA")

    fold
    assert_equal @parent, convo.reload.project
    assert_equal @parent, task.reload.project
    assert_equal @parent, doc.reload.project
    assert_equal @parent, extra_env.reload.project
    [@inside, @sibling].each do |p|
      assert p.reload.archived?
      assert_match(/folded into/, p.description)
      assert_equal 0, Projects::WorktreeFolder::TABLES.sum { |t| ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{t} WHERE project_id = '#{p.id}'").to_i }
    end
    assert Project.exists?(@inside.id)
  end

  test "an environment the parent already has is merged and its tasks re-pointed" do
    dup_env = @inside.environments.find_by!(name: "Development")
    task = Task.create!(project: @inside, title: "On dev", environment: dup_env)
    result, = fold
    assert_equal 3, ours(result).find { |f| f.project == @inside }.clashes["environments"]
    assert_equal @parent.environments.find_by!(name: "Development"), task.reload.environment
    assert_not Environment.exists?(dup_env.id)
    assert_equal 3, @parent.environments.count
  end

  test "a fact the parent already knows is merged, a clashing document keeps both" do
    KnowledgeFact.create!(project: @parent, body: "Uses pnpm", fingerprint: "fp-#{@tag}", times_seen: 2, last_seen_at: 3.days.ago)
    KnowledgeFact.create!(project: @inside, body: "Uses pnpm", fingerprint: "fp-#{@tag}", times_seen: 5, last_seen_at: 1.hour.ago)
    Document.create!(project: @parent, title: "Plan", slug: "plan-#{@tag}", kind: "plan", body: "parent")
    Document.create!(project: @inside, title: "Plan", slug: "plan-#{@tag}", kind: "plan", body: "worktree")
    agent = Agent.create!(project: @inside, kind: "agent", name: "reviewer-#{@tag}", scope: "project")
    kept = Agent.create!(project: @parent, kind: "agent", name: "reviewer-#{@tag}", scope: "project")

    fold
    facts = @parent.knowledge_facts.where(fingerprint: "fp-#{@tag}")
    assert_equal 1, facts.count
    assert_equal 7, facts.first.times_seen
    assert_operator facts.first.last_seen_at, :>, 2.hours.ago
    assert_equal %w[parent worktree], @parent.documents.where("slug LIKE ?", "plan-#{@tag}%").order(:slug).pluck(:body)
    assert @parent.documents.exists?(slug: "plan-#{@tag}-from-#{@inside.slug}")
    assert_not Agent.exists?(agent.id)
    assert Agent.exists?(kept.id)
  end

  test "a worktree project with no parent project is listed and left alone" do
    orphan = leftover("orphan", "/tmp/fold-#{@tag}/gone/.claude/worktrees/agent-x")
    Conversation.create!(project: orphan, session_id: "o-#{@tag}")
    result, text = fold
    assert_includes result.unresolved, orphan
    assert_match(/left alone:.*\n(.*\n)*\s+#{orphan.slug}/, text)
    assert_nil orphan.reload.archived_at
    assert_equal 1, orphan.conversations.count
  end

  test "folding twice is a no-op the second time" do
    Conversation.create!(project: @inside, session_id: "c-#{@tag}")
    fold
    result, = fold
    assert_empty ours(result)
    assert_equal 1, @parent.conversations.count
  end
end
