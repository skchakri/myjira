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

ActiveRecord::Schema[8.1].define(version: 2026_06_28_000012) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "active_storage_attachments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.uuid "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "agent_schedules", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agent_id"
    t.integer "consecutive_failures", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "cron", null: false
    t.boolean "enabled", default: true, null: false
    t.text "last_error"
    t.datetime "last_failed_at"
    t.uuid "last_launch_id"
    t.datetime "last_run_at"
    t.string "last_status"
    t.string "model"
    t.datetime "next_run_at"
    t.string "permission_mode"
    t.uuid "playbook_id"
    t.uuid "project_id", null: false
    t.text "prompt", null: false
    t.text "task"
    t.datetime "updated_at", null: false
    t.index ["agent_id"], name: "index_agent_schedules_on_agent_id"
    t.index ["enabled", "next_run_at"], name: "index_agent_schedules_on_enabled_and_next_run_at"
    t.index ["last_launch_id"], name: "index_agent_schedules_on_last_launch_id"
    t.index ["playbook_id"], name: "index_agent_schedules_on_playbook_id"
    t.index ["project_id"], name: "index_agent_schedules_on_project_id"
  end

  create_table "agents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "category"
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "discovered_at"
    t.boolean "enabled", default: true, null: false
    t.string "kind", null: false
    t.string "model"
    t.string "name", null: false
    t.uuid "project_id"
    t.string "scope", default: "project", null: false
    t.string "source_path"
    t.jsonb "tools", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["category"], name: "index_agents_on_category"
    t.index ["enabled"], name: "index_agents_on_enabled"
    t.index ["kind", "name"], name: "index_agents_on_global_kind_name", unique: true, where: "(project_id IS NULL)"
    t.index ["project_id", "kind", "name"], name: "index_agents_on_project_kind_name", unique: true
    t.index ["project_id"], name: "index_agents_on_project_id"
  end

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
    t.virtual "search_vector", type: :tsvector, as: "to_tsvector('english'::regconfig, ((COALESCE(body, ''::text) || ' '::text) || COALESCE((payload)::text, ''::text)))", stored: true
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "ext_id"], name: "index_conversation_messages_on_conversation_id_and_ext_id", unique: true
    t.index ["conversation_id", "position"], name: "index_conversation_messages_on_conversation_id_and_position"
    t.index ["conversation_id"], name: "index_conversation_messages_on_conversation_id"
    t.index ["search_vector"], name: "index_conversation_messages_on_search_vector", using: :gin
  end

  create_table "conversations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "board_enriched_at"
    t.integer "board_enriched_count", default: 0, null: false
    t.bigint "cache_tokens", default: 0, null: false
    t.decimal "cost_usd", precision: 10, scale: 4, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.string "cwd"
    t.datetime "facts_extracted_at"
    t.string "git_branch"
    t.jsonb "highlights", default: [], null: false
    t.bigint "input_tokens", default: 0, null: false
    t.text "last_context"
    t.datetime "last_message_at"
    t.integer "message_count", default: 0, null: false
    t.string "model"
    t.boolean "model_deprecated", default: false, null: false
    t.string "name"
    t.bigint "output_tokens", default: 0, null: false
    t.uuid "project_id", null: false
    t.jsonb "prs", default: [], null: false
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
    t.text "labels", default: [], null: false, array: true
    t.uuid "project_id", null: false
    t.virtual "search_vector", type: :tsvector, as: "to_tsvector('english'::regconfig, (((COALESCE(title, ''::character varying))::text || ' '::text) || COALESCE(description, ''::text)))", stored: true
    t.string "severity", default: "medium", null: false
    t.string "status", default: "open", null: false
    t.uuid "task_id"
    t.uuid "test_result_id"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["labels"], name: "index_follow_up_tasks_on_labels", using: :gin
    t.index ["project_id"], name: "index_follow_up_tasks_on_project_id"
    t.index ["search_vector"], name: "index_follow_up_tasks_on_search_vector", using: :gin
    t.index ["severity"], name: "index_follow_up_tasks_on_severity"
    t.index ["status"], name: "index_follow_up_tasks_on_status"
    t.index ["task_id"], name: "index_follow_up_tasks_on_task_id"
    t.index ["test_result_id"], name: "index_follow_up_tasks_on_test_result_id"
  end

  create_table "jira_connections", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "api_token"
    t.datetime "created_at", null: false
    t.string "email"
    t.string "site_url"
    t.datetime "updated_at", null: false
  end

  create_table "knowledge_facts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.string "fingerprint", null: false
    t.datetime "last_seen_at"
    t.uuid "project_id", null: false
    t.uuid "source_conversation_id"
    t.integer "times_seen", default: 1, null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "fingerprint"], name: "index_knowledge_facts_on_project_id_and_fingerprint", unique: true
    t.index ["project_id", "last_seen_at"], name: "index_knowledge_facts_on_project_id_and_last_seen_at"
    t.index ["project_id"], name: "index_knowledge_facts_on_project_id"
  end

  create_table "mcp_installs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "action", default: "add", null: false
    t.jsonb "args", default: [], null: false
    t.string "catalog_key"
    t.string "command"
    t.datetime "created_at", null: false
    t.text "env"
    t.text "error"
    t.jsonb "header", default: [], null: false
    t.datetime "installed_at"
    t.string "name", null: false
    t.uuid "project_id"
    t.string "scope", default: "user", null: false
    t.string "status", default: "pending", null: false
    t.string "transport", default: "stdio", null: false
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["project_id"], name: "index_mcp_installs_on_project_id"
    t.index ["status"], name: "index_mcp_installs_on_status"
  end

  create_table "mcp_servers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "args", default: [], null: false
    t.string "command"
    t.datetime "created_at", null: false
    t.datetime "discovered_at"
    t.boolean "enabled", default: true, null: false
    t.jsonb "env_keys", default: [], null: false
    t.string "name", null: false
    t.uuid "project_id"
    t.string "scope", default: "user", null: false
    t.string "status", default: "pending", null: false
    t.text "status_detail"
    t.string "transport", default: "stdio", null: false
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["enabled"], name: "index_mcp_servers_on_enabled"
    t.index ["project_id", "scope", "name"], name: "index_mcp_servers_on_project_scope_name", unique: true
    t.index ["project_id"], name: "index_mcp_servers_on_project_id"
    t.index ["scope", "name"], name: "index_mcp_servers_on_global_scope_name", unique: true, where: "(project_id IS NULL)"
  end

  create_table "playbook_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agent_schedule_id"
    t.datetime "created_at", null: false
    t.datetime "evaluated_at"
    t.text "notes"
    t.uuid "playbook_id", null: false
    t.string "result", default: "pending", null: false
    t.uuid "session_launch_id"
    t.datetime "updated_at", null: false
    t.index ["agent_schedule_id"], name: "index_playbook_runs_on_agent_schedule_id"
    t.index ["playbook_id"], name: "index_playbook_runs_on_playbook_id"
    t.index ["session_launch_id"], name: "index_playbook_runs_on_session_launch_id"
  end

  create_table "playbooks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agent_id"
    t.text "body", null: false
    t.integer "budget_cap_cents"
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.text "guardrails"
    t.string "model"
    t.string "name", null: false
    t.string "permission_mode"
    t.uuid "project_id"
    t.text "success_criteria"
    t.datetime "updated_at", null: false
    t.index ["agent_id"], name: "index_playbooks_on_agent_id"
    t.index ["project_id"], name: "index_playbooks_on_project_id"
  end

  create_table "projects", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "archived_at"
    t.integer "autopilot_budget_cap_cents"
    t.integer "autopilot_daily_cap", default: 10, null: false
    t.boolean "autopilot_enabled", default: false, null: false
    t.boolean "autopilot_paused", default: false, null: false
    t.boolean "autopilot_review_enabled", default: true, null: false
    t.integer "autopilot_runs_count", default: 0, null: false
    t.date "autopilot_runs_on"
    t.string "base_branch"
    t.jsonb "branches", default: [], null: false
    t.datetime "branches_synced_at"
    t.string "category"
    t.string "color"
    t.datetime "created_at", null: false
    t.string "default_base_url"
    t.text "description"
    t.boolean "listed", default: false, null: false
    t.text "memory_preamble"
    t.string "name", null: false
    t.string "repo_path"
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["archived_at"], name: "index_projects_on_archived_at"
    t.index ["category"], name: "index_projects_on_category"
    t.index ["listed"], name: "index_projects_on_listed"
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

  create_table "session_launches", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agent_id"
    t.datetime "budget_alerted_at"
    t.integer "budget_cap_cents"
    t.bigint "cache_creation_tokens"
    t.bigint "cache_read_tokens"
    t.uuid "conversation_id"
    t.datetime "created_at", null: false
    t.text "error"
    t.integer "estimated_cost_cents"
    t.integer "exit_code"
    t.datetime "launched_at"
    t.integer "max_turns"
    t.string "model"
    t.boolean "over_budget", default: false, null: false
    t.datetime "over_budget_at"
    t.string "permission_mode"
    t.string "pipeline_step"
    t.uuid "project_id", null: false
    t.text "prompt", null: false
    t.string "repo_path", null: false
    t.string "resume_of_session_id"
    t.string "session_id", null: false
    t.string "status", default: "pending", null: false
    t.uuid "task_id"
    t.string "tmux_target"
    t.bigint "token_input"
    t.bigint "token_output"
    t.datetime "updated_at", null: false
    t.index ["agent_id"], name: "index_session_launches_on_agent_id"
    t.index ["conversation_id"], name: "index_session_launches_on_conversation_id"
    t.index ["project_id", "created_at"], name: "index_session_launches_on_project_id_and_created_at"
    t.index ["project_id"], name: "index_session_launches_on_project_id"
    t.index ["session_id"], name: "index_session_launches_on_session_id", unique: true
    t.index ["status"], name: "index_session_launches_on_status"
    t.index ["task_id"], name: "index_session_launches_on_task_id"
  end

  create_table "settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.text "value"
    t.index ["key"], name: "index_settings_on_key", unique: true
  end

  create_table "task_comments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "author", default: "you", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.uuid "task_id", null: false
    t.datetime "updated_at", null: false
    t.index ["task_id"], name: "index_task_comments_on_task_id"
  end

  create_table "tasks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "agent_notes"
    t.string "agent_role", default: "unassigned", null: false
    t.integer "autopilot_attempts", default: 0, null: false
    t.string "board_state", default: "pending", null: false
    t.string "branch_name"
    t.text "changelog_summary"
    t.datetime "conflict_resolution_at"
    t.datetime "created_at", null: false
    t.text "description"
    t.uuid "environment_id"
    t.string "external_ref"
    t.string "external_url"
    t.datetime "finished_at"
    t.text "implementation_notes"
    t.datetime "implemented_at"
    t.string "item_type", default: "task", null: false
    t.text "labels", default: [], null: false, array: true
    t.uuid "last_conversation_id"
    t.uuid "last_test_run_id"
    t.datetime "merge_requested_at"
    t.datetime "picked_up_at"
    t.text "plan"
    t.datetime "plan_updated_at"
    t.integer "position"
    t.text "pr_diff"
    t.string "pr_mergeable"
    t.integer "pr_number"
    t.string "pr_state"
    t.datetime "pr_synced_at"
    t.string "pr_url"
    t.string "priority", default: "normal"
    t.uuid "project_id", null: false
    t.virtual "search_vector", type: :tsvector, as: "to_tsvector('english'::regconfig, (((((((((COALESCE(title, ''::character varying))::text || ' '::text) || COALESCE(description, ''::text)) || ' '::text) || COALESCE(implementation_notes, ''::text)) || ' '::text) || COALESCE(plan, ''::text)) || ' '::text) || COALESCE(agent_notes, ''::text)))", stored: true
    t.string "source", default: "claude-cli"
    t.string "status", default: "open", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["environment_id"], name: "index_tasks_on_environment_id"
    t.index ["external_ref"], name: "index_tasks_on_external_ref"
    t.index ["item_type"], name: "index_tasks_on_item_type"
    t.index ["labels"], name: "index_tasks_on_labels", using: :gin
    t.index ["last_conversation_id"], name: "index_tasks_on_last_conversation_id"
    t.index ["last_test_run_id"], name: "index_tasks_on_last_test_run_id"
    t.index ["merge_requested_at"], name: "index_tasks_on_merge_requested_at"
    t.index ["project_id", "board_state"], name: "index_tasks_on_project_id_and_board_state"
    t.index ["project_id", "position"], name: "index_tasks_on_project_id_and_position"
    t.index ["project_id"], name: "index_tasks_on_project_id"
    t.index ["search_vector"], name: "index_tasks_on_search_vector", using: :gin
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
    t.virtual "search_vector", type: :tsvector, as: "to_tsvector('english'::regconfig, ((COALESCE(notes, ''::text) || ' '::text) || COALESCE(actual_result, ''::text)))", stored: true
    t.string "status", default: "pending", null: false
    t.uuid "test_case_id", null: false
    t.uuid "test_run_id", null: false
    t.datetime "updated_at", null: false
    t.index ["search_vector"], name: "index_test_results_on_search_vector", using: :gin
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

  create_table "worklog_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "label", default: "", null: false
    t.string "name", null: false
    t.datetime "occurred_at", null: false
    t.jsonb "payload", default: {}, null: false
    t.uuid "project_id"
    t.string "status", default: "info", null: false
    t.uuid "subject_id", null: false
    t.string "subject_type", null: false
    t.index ["project_id"], name: "index_worklog_events_on_project_id"
    t.index ["subject_type", "subject_id", "occurred_at"], name: "index_worklog_events_on_subject_and_time"
    t.index ["subject_type", "subject_id"], name: "index_worklog_events_on_subject"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "agent_schedules", "agents"
  add_foreign_key "agent_schedules", "projects"
  add_foreign_key "agent_schedules", "session_launches", column: "last_launch_id"
  add_foreign_key "agents", "projects"
  add_foreign_key "browser_messages", "browser_tasks"
  add_foreign_key "browser_tasks", "conversations"
  add_foreign_key "browser_tasks", "projects"
  add_foreign_key "conversation_messages", "conversations"
  add_foreign_key "conversations", "projects"
  add_foreign_key "environments", "projects"
  add_foreign_key "follow_up_tasks", "projects"
  add_foreign_key "follow_up_tasks", "tasks"
  add_foreign_key "follow_up_tasks", "test_results"
  add_foreign_key "knowledge_facts", "projects"
  add_foreign_key "mcp_installs", "projects"
  add_foreign_key "mcp_servers", "projects"
  add_foreign_key "playbook_runs", "playbooks"
  add_foreign_key "playbook_runs", "session_launches"
  add_foreign_key "playbooks", "agents"
  add_foreign_key "playbooks", "projects"
  add_foreign_key "session_commands", "conversations"
  add_foreign_key "session_launches", "agents"
  add_foreign_key "session_launches", "conversations"
  add_foreign_key "session_launches", "projects"
  add_foreign_key "session_launches", "tasks", on_delete: :nullify
  add_foreign_key "task_comments", "tasks"
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
