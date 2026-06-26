require "test_helper"

# Verifies that the shared/_field partial renders required markers, inline
# per-field errors, and consistent input styling across the core CRUD forms.
class SharedFieldPartialTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(
      name: "Field Partial Test",
      slug: "field-partial-#{SecureRandom.hex(3)}",
      repo_path: "/tmp/field-partial-test"
    )
  end

  # --- Projects form ---

  test "GET new project form shows required asterisk on name field" do
    get new_project_path
    assert_response :success
    assert_select "span.text-rose-500", minimum: 1
  end

  test "POST project with blank name re-renders with inline field error" do
    post projects_path, params: { project: { name: "", slug: "", description: "" } }
    assert_response :unprocessable_entity
    # Inline per-field error message (from errors[:name], not the summary)
    assert_select "p.text-rose-600"
    assert_match "can&#39;t be blank", response.body
  end

  test "POST project with valid data succeeds" do
    assert_difference -> { Project.count }, 1 do
      post projects_path, params: { project: { name: "Valid Project #{SecureRandom.hex(3)}" } }
    end
    assert_response :redirect
  end

  # --- Environments form ---

  test "GET new environment form shows required asterisk on name field" do
    get new_project_environment_path(@project)
    assert_response :success
    assert_select "span.text-rose-500", minimum: 1
  end

  test "POST environment with blank name re-renders with inline field error" do
    post project_environments_path(@project), params: { environment: { name: "" } }
    assert_response :unprocessable_entity
    assert_select "p.text-rose-600"
    assert_match "can&#39;t be blank", response.body
  end

  test "POST environment with valid name succeeds" do
    assert_difference -> { @project.environments.count }, 1 do
      post project_environments_path(@project), params: {
        environment: { name: "Staging-#{SecureRandom.hex(3)}" }
      }
    end
    assert_response :redirect
  end

  # --- Tasks form ---

  test "GET new task form shows required asterisk on title field" do
    get new_project_task_path(@project)
    assert_response :success
    assert_select "span.text-rose-500", minimum: 1
  end

  test "POST task with blank title re-renders with inline field error" do
    post project_tasks_path(@project), params: { task: { title: "" } }
    assert_response :unprocessable_entity
    assert_select "p.text-rose-600"
    assert_match "can&#39;t be blank", response.body
  end

  test "POST task with valid title succeeds" do
    assert_difference -> { @project.tasks.count }, 1 do
      post project_tasks_path(@project), params: { task: { title: "A valid task title" } }
    end
    assert_response :redirect
  end
end
