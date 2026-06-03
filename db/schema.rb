# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_06_03_000004) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "browser_messages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "body", null: false
    t.uuid "browser_task_id", null: false
    t.datetime "created_at", null: false
    t.string "kind", default: "message", null: false
    t.jsonb "payload", default: {}, null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.index ["browser_task_id", "created_at"], name: "index_browser_messages_on_browser_task_id_and_created_at"
  end

  create_table "browser_tasks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "browser_session_id"
    t.string "cli_session_id"
    t.uuid "conversation_id"
    t.datetime "created_at", null: false
    t.datetime "humanized_at"
    t.text "humanized_summary"
    t.string "initiated_by"
    t.text "instructions"
    t.datetime "last_activity_at"
    t.string "priority", default: "normal"
    t.uuid "project_id", null: false
    t.string "source", default: "claude-cli"
    t.string "status", default: "queued", null: false
    t.string "target_url"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["browser_session_id"], name: "index_browser_tasks_on_browser_session_id"
    t.index ["cli_session_id"], name: "index_browser_tasks_on_cli_session_id"
    t.index ["conversation_id"], name: "index_browser_tasks_on_conversation_id"
    t.index ["last_activity_at"], name: "index_browser_tasks_on_last_activity_at"
    t.index ["project_id"], name: "index_browser_tasks_on_project_id"
    t.index ["status"], name: "index_browser_tasks_on_status"
  end

  create_table "conversation_messages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "body"
    t.uuid "conversation_id", null: false
    t.datetime "created_at", null: false
    t.string "ext_id", null: false
    t.string "kind", default: "message", null: false
    t.datetime "occurred_at"
    t.jsonb "payload", default: {}, null: false
    t.integer "position", default: 0, null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "ext_id"], name: "index_conversation_messages_on_conversation_id_and_ext_id", unique: true
    t.index ["conversation_id", "position"], name: "index_conversation_messages_on_conversation_id_and_position"
    t.index ["conversation_id"], name: "index_conversation_messages_on_conversation_id"
  end

  create_table "conversations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "cwd"
    t.string "git_branch"
    t.datetime "last_message_at"
    t.integer "message_count", default: 0, null: false
    t.string "model"
    t.string "name"
    t.uuid "project_id", null: false
    t.string "session_id", null: false
    t.string "source", default: "claude-cli", null: false
    t.datetime "started_at"
    t.datetime "summarized_at"
    t.text "summary"
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["last_message_at"], name: "index_conversations_on_last_message_at"
    t.index ["project_id"], name: "index_conversations_on_project_id"
    t.index ["session_id"], name: "index_conversations_on_session_id", unique: true
  end

  create_table "environments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "base_url"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.text "notes"
    t.uuid "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "name"], name: "index_environments_on_project_id_and_name", unique: true
    t.index ["project_id"], name: "index_environments_on_project_id"
  end

  create_table "follow_up_tasks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "kind", default: "gap", null: false
    t.uuid "project_id", null: false
    t.string "severity", default: "medium", null: false
    t.string "status", default: "open", null: false
    t.uuid "task_id"
    t.uuid "test_result_id"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_follow_up_tasks_on_project_id"
    t.index ["severity"], name: "index_follow_up_tasks_on_severity"
    t.index ["status"], name: "index_follow_up_tasks_on_status"
    t.index ["task_id"], name: "index_follow_up_tasks_on_task_id"
    t.index ["test_result_id"], name: "index_follow_up_tasks_on_test_result_id"
  end

  create_table "projects", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "color"
    t.datetime "created_at", null: false
    t.string "default_base_url"
    t.text "description"
    t.string "name", null: false
    t.string "repo_path"
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_projects_on_slug", unique: true
  end

  create_table "session_commands", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "body", null: false
    t.uuid "conversation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "responded_at"
    t.text "result"
    t.string "source", default: "web"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "created_at"], name: "index_session_commands_on_conversation_id_and_created_at"
    t.index ["conversation_id"], name: "index_session_commands_on_conversation_id"
    t.index ["status"], name: "index_session_commands_on_status"
  end

  create_table "tasks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.uuid "environment_id"
    t.string "external_ref"
    t.text "implementation_notes"
    t.datetime "implemented_at"
    t.string "priority", default: "normal"
    t.uuid "project_id", null: false
    t.string "source", default: "claude-cli"
    t.string "status", default: "open", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["environment_id"], name: "index_tasks_on_environment_id"
    t.index ["external_ref"], name: "index_tasks_on_external_ref"
    t.index ["project_id"], name: "index_tasks_on_project_id"
    t.index ["status"], name: "index_tasks_on_status"
  end

  create_table "test_cases", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "api_call"
    t.datetime "created_at", null: false
    t.text "expected_result"
    t.text "notes"
    t.integer "position", default: 0, null: false
    t.text "steps"
    t.uuid "task_id"
    t.uuid "test_plan_id", null: false
    t.string "tier", default: "acceptance", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["task_id"], name: "index_test_cases_on_task_id"
    t.index ["test_plan_id", "position"], name: "index_test_cases_on_test_plan_id_and_position"
    t.index ["test_plan_id"], name: "index_test_cases_on_test_plan_id"
    t.index ["tier"], name: "index_test_cases_on_tier"
  end

  create_table "test_plan_tasks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "task_id", null: false
    t.uuid "test_plan_id", null: false
    t.datetime "updated_at", null: false
    t.index ["task_id"], name: "index_test_plan_tasks_on_task_id"
    t.index ["test_plan_id", "task_id"], name: "index_test_plan_tasks_on_test_plan_id_and_task_id", unique: true
    t.index ["test_plan_id"], name: "index_test_plan_tasks_on_test_plan_id"
  end

  create_table "test_plans", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.uuid "project_id", null: false
    t.string "status", default: "draft", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_test_plans_on_project_id"
  end

  create_table "test_results", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "actual_result"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.text "notes"
    t.string "screenshot_url"
    t.string "status", default: "pending", null: false
    t.uuid "test_case_id", null: false
    t.uuid "test_run_id", null: false
    t.datetime "updated_at", null: false
    t.index ["test_case_id"], name: "index_test_results_on_test_case_id"
    t.index ["test_run_id", "test_case_id"], name: "index_test_results_on_test_run_id_and_test_case_id", unique: true
    t.index ["test_run_id"], name: "index_test_results_on_test_run_id"
  end

  create_table "test_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "blocked_count", default: 0
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.uuid "environment_id"
    t.integer "failed_count", default: 0
    t.string "initiated_by"
    t.integer "passed_count", default: 0
    t.integer "skipped_count", default: 0
    t.datetime "started_at"
    t.string "status", default: "running", null: false
    t.text "summary"
    t.uuid "test_plan_id", null: false
    t.integer "total_cases", default: 0
    t.datetime "updated_at", null: false
    t.index ["environment_id"], name: "index_test_runs_on_environment_id"
    t.index ["status"], name: "index_test_runs_on_status"
    t.index ["test_plan_id"], name: "index_test_runs_on_test_plan_id"
  end

  add_foreign_key "browser_messages", "browser_tasks"
  add_foreign_key "browser_tasks", "conversations"
  add_foreign_key "browser_tasks", "projects"
  add_foreign_key "conversation_messages", "conversations"
  add_foreign_key "conversations", "projects"
  add_foreign_key "environments", "projects"
  add_foreign_key "follow_up_tasks", "projects"
  add_foreign_key "follow_up_tasks", "tasks"
  add_foreign_key "follow_up_tasks", "test_results"
  add_foreign_key "session_commands", "conversations"
  add_foreign_key "tasks", "environments"
  add_foreign_key "tasks", "projects"
  add_foreign_key "test_cases", "tasks"
  add_foreign_key "test_cases", "test_plans"
  add_foreign_key "test_plan_tasks", "tasks"
  add_foreign_key "test_plan_tasks", "test_plans"
  add_foreign_key "test_plans", "projects"
  add_foreign_key "test_results", "test_cases"
  add_foreign_key "test_results", "test_runs"
  add_foreign_key "test_runs", "environments"
  add_foreign_key "test_runs", "test_plans"
end
