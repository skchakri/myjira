class AddTriageSuggestionToTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :tasks, :triage_suggestion, :jsonb
  end
end
