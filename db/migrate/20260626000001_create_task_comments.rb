# Append-only notes on a board item — left by a human on the board/task page or
# posted by a board agent via the API. Surfaced as a dated log on the task page.
class CreateTaskComments < ActiveRecord::Migration[8.1]
  def change
    create_table :task_comments, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :task, type: :uuid, null: false, foreign_key: true, index: true
      t.string :author, null: false, default: "you"
      t.text :body, null: false
      t.timestamps
    end
  end
end
