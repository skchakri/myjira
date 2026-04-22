class CreateCoreSchema < ActiveRecord::Migration[8.1]
  def change
    create_table :projects, id: :uuid do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :repo_path
      t.text :description
      t.string :default_base_url
      t.timestamps
    end
    add_index :projects, :slug, unique: true

    create_table :environments, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: true, index: true
      t.string :name, null: false
      t.string :base_url
      t.text :notes
      t.timestamps
    end
    add_index :environments, [:project_id, :name], unique: true

    create_table :tasks, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: true, index: true
      t.references :environment, type: :uuid, null: true, foreign_key: true, index: true
      t.string :external_ref
      t.string :title, null: false
      t.text :description
      t.text :implementation_notes
      t.string :status, null: false, default: "open"
      t.string :priority, default: "normal"
      t.string :source, default: "claude-cli"
      t.datetime :implemented_at
      t.timestamps
    end
    add_index :tasks, :status
    add_index :tasks, :external_ref

    create_table :test_plans, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: true, index: true
      t.string :title, null: false
      t.text :description
      t.string :status, null: false, default: "draft"
      t.timestamps
    end

    create_table :test_plan_tasks, id: :uuid do |t|
      t.references :test_plan, type: :uuid, null: false, foreign_key: true, index: true
      t.references :task, type: :uuid, null: false, foreign_key: true, index: true
      t.timestamps
    end
    add_index :test_plan_tasks, [:test_plan_id, :task_id], unique: true

    create_table :test_cases, id: :uuid do |t|
      t.references :test_plan, type: :uuid, null: false, foreign_key: true, index: true
      t.references :task, type: :uuid, null: true, foreign_key: true, index: true
      t.integer :position, null: false, default: 0
      t.string :title, null: false
      t.text :steps
      t.text :expected_result
      t.text :api_call
      t.text :notes
      t.timestamps
    end
    add_index :test_cases, [:test_plan_id, :position]

    create_table :test_runs, id: :uuid do |t|
      t.references :test_plan, type: :uuid, null: false, foreign_key: true, index: true
      t.references :environment, type: :uuid, null: true, foreign_key: true, index: true
      t.string :status, null: false, default: "running"
      t.string :initiated_by
      t.datetime :started_at
      t.datetime :completed_at
      t.text :summary
      t.integer :total_cases, default: 0
      t.integer :passed_count, default: 0
      t.integer :failed_count, default: 0
      t.integer :blocked_count, default: 0
      t.integer :skipped_count, default: 0
      t.timestamps
    end
    add_index :test_runs, :status

    create_table :test_results, id: :uuid do |t|
      t.references :test_run, type: :uuid, null: false, foreign_key: true, index: true
      t.references :test_case, type: :uuid, null: false, foreign_key: true, index: true
      t.string :status, null: false, default: "pending"
      t.text :actual_result
      t.text :notes
      t.string :screenshot_url
      t.datetime :completed_at
      t.timestamps
    end
    add_index :test_results, [:test_run_id, :test_case_id], unique: true

    create_table :follow_up_tasks, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: true, index: true
      t.references :task, type: :uuid, null: true, foreign_key: true, index: true
      t.references :test_result, type: :uuid, null: true, foreign_key: true, index: true
      t.string :title, null: false
      t.text :description
      t.string :severity, null: false, default: "medium"
      t.string :status, null: false, default: "open"
      t.string :kind, null: false, default: "gap"
      t.timestamps
    end
    add_index :follow_up_tasks, :status
    add_index :follow_up_tasks, :severity
  end
end
