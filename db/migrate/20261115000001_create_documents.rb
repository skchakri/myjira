class CreateDocuments < ActiveRecord::Migration[8.0]
  def change
    create_table :documents, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: true
      t.references :task, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string  :title, null: false
      t.string  :slug,  null: false
      t.string  :kind,  null: false, default: "note"
      t.text    :body,  null: false, default: ""
      t.string  :source_path
      t.string  :cli_session_id
      t.string  :author, null: false, default: "claude-cli"
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :documents, [:project_id, :slug], unique: true
    add_index :documents, [:project_id, :updated_at]

    create_table :document_revisions, id: :uuid do |t|
      t.references :document, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.integer :version, null: false
      t.string  :title, null: false
      t.text    :body,  null: false, default: ""
      t.string  :author
      t.datetime :created_at, null: false
    end
    add_index :document_revisions, [:document_id, :version], unique: true
  end
end
