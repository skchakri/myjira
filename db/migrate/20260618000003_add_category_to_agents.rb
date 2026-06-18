# Categorise discovered agents (Phase 3 of the agent-authoring feature). The
# daemon can send a `category:` frontmatter value; when it doesn't, Agent.classify
# infers one from the name/description/tools. Backfill existing rows on migrate.
class AddCategoryToAgents < ActiveRecord::Migration[8.1]
  def up
    add_column :agents, :category, :string
    add_index :agents, :category

    say_with_time "classifying existing agents" do
      Agent.reset_column_information
      Agent.find_each do |a|
        a.update_columns(category: Agent.classify(a.name, a.description, a.tools)) # rubocop:disable Rails/SkipsModelValidations
      end
    end
  end

  def down
    remove_index :agents, :category
    remove_column :agents, :category
  end
end
