class AddChangelogSummaryToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :changelog_summary, :text
  end
end
