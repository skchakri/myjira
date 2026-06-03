class AddHumanizedSummaryToBrowserTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :browser_tasks, :humanized_summary, :text
    add_column :browser_tasks, :humanized_at, :datetime
  end
end
