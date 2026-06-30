class AddMergedIntoToTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :tasks, :merged_into_id, :uuid
    add_index  :tasks, :merged_into_id
  end
end
