class AddLabelsToTasksAndFollowUpTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :labels, :text, array: true, null: false, default: []
    add_column :follow_up_tasks, :labels, :text, array: true, null: false, default: []

    # GIN indexes back the containment (@>) filters used by the with_label scope.
    add_index :tasks, :labels, using: :gin
    add_index :follow_up_tasks, :labels, using: :gin
  end
end
