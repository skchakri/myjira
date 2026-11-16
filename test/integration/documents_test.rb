require "test_helper"

# Per-project Documents: the CLI-facing API (upsert + repo_path resolution +
# versioning) and the web list / reader / editor.
class DocumentsTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Docs Test", slug: "docs-#{SecureRandom.hex(3)}",
                               repo_path: "/tmp/docs-test-#{SecureRandom.hex(3)}")
  end

  test "API create upserts by title-derived slug and keeps prior versions" do
    post "/api/v1/projects/#{@project.slug}/documents",
         params: { document: { title: "Rollout Plan", kind: "plan", body: "v1 text" } }, as: :json
    assert_response :created
    assert_equal "rollout-plan", response.parsed_body["slug"]
    assert_equal 1, response.parsed_body["version"]
    assert_match %r{/projects/#{@project.slug}/documents/rollout-plan\z}, response.parsed_body.dig("urls", "web")

    post "/api/v1/projects/#{@project.slug}/documents",
         params: { document: { title: "Rollout Plan", kind: "plan", body: "v2 text" } }, as: :json
    assert_response :ok
    assert_equal 2, response.parsed_body["version"]

    doc = @project.documents.sole
    assert_equal "v2 text", doc.body
    assert_equal [1], doc.revisions.pluck(:version)
    assert_equal "v1 text", doc.revisions.first.body
  end

  test "unchanged re-file does not bump the version" do
    2.times do
      post "/api/v1/projects/#{@project.slug}/documents",
           params: { document: { title: "Same", body: "same" } }, as: :json
    end
    assert_equal 1, @project.documents.sole.version
  end

  test "repo-wide upsert resolves the project from any folder inside repo_path" do
    post "/api/v1/documents",
         params: { repo_path: "#{@project.repo_path}/app/models", document: { title: "Spec A", kind: "spec", body: "x" } },
         as: :json
    assert_response :created
    assert_equal @project.slug, response.parsed_body["project"]
  end

  test "repo-wide upsert 404s with a hint when no project matches" do
    post "/api/v1/documents", params: { repo_path: "/nope/#{SecureRandom.hex(4)}", document: { title: "X" } }, as: :json
    assert_response :not_found
    assert_match(/repo_path/, response.parsed_body["message"])
  end

  test "a sibling folder sharing a prefix does not match" do
    post "/api/v1/documents", params: { repo_path: "#{@project.repo_path}-other", document: { title: "X" } }, as: :json
    assert_response :not_found
  end

  test "API show returns the body; index omits it and filters by kind" do
    @project.documents.create!(title: "A plan", kind: "plan", body: "plan body")
    @project.documents.create!(title: "A note", kind: "note", body: "note body")

    get "/api/v1/projects/#{@project.slug}/documents", params: { kind: "plan" }
    assert_equal ["a-plan"], response.parsed_body.map { |d| d["slug"] }
    assert_nil response.parsed_body.first["body"]

    get "/api/v1/projects/#{@project.slug}/documents/a-plan"
    assert_equal "plan body", response.parsed_body["body"]
  end

  test "invalid kind is rejected" do
    post "/api/v1/projects/#{@project.slug}/documents", params: { document: { title: "X", kind: "bogus" } }, as: :json
    assert_response :unprocessable_entity
  end

  test "web index shows an empty state, then lists documents" do
    get project_documents_path(@project)
    assert_response :success
    assert_match(/No documents yet/, response.body)

    @project.documents.create!(title: "Release notes", kind: "report", body: "# Hi")
    get project_documents_path(@project)
    assert_select "a", text: "Release notes"
  end

  test "web show renders markdown safely and an older version on request" do
    doc = @project.documents.create!(title: "Doc", body: "**first** <script>alert(1)</script>")
    doc.update!(body: "**second**")

    get project_document_path(@project, doc)
    assert_response :success
    assert_select "strong", text: "second"

    get project_document_path(@project, doc, version: 1)
    assert_select "strong", text: "first"
    assert_no_match(/<script>alert/, response.body)
    assert_match(/older copy/, response.body)
  end

  test "web create, update and destroy" do
    post project_documents_path(@project), params: { document: { title: "Hand written", kind: "note", body: "a" } }
    doc = @project.documents.find_by!(slug: "hand-written")
    assert_redirected_to project_document_path(@project, doc)
    assert_equal "web", doc.author

    patch project_document_path(@project, doc), params: { document: { body: "b" } }
    assert_equal 2, doc.reload.version

    delete project_document_path(@project, doc)
    assert_redirected_to project_documents_path(@project)
    assert_not Document.exists?(doc.id)
    assert_equal 0, DocumentRevision.where(document_id: doc.id).count
  end

  test "web create with a blank title re-renders with an error" do
    post project_documents_path(@project), params: { document: { title: "", body: "a" } }
    assert_response :unprocessable_entity
    assert_match(/Title can&#39;t be blank/, response.body)
  end
end
