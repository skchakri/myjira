class AddExternalUrlToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :external_url, :string
  end
end
