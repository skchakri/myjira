# Group projects into workspaces: pyr (per-client iCentris/pyr work under
# platform/clients), skchakri (personal apps), icentris (the iCentris platform),
# other (everything else). Derived from repo_path; editable afterwards. Backfilled.
class AddCategoryToProjects < ActiveRecord::Migration[8.1]
  def up
    add_column :projects, :category, :string
    add_index :projects, :category

    say_with_time "categorising existing projects" do
      Project.reset_column_information
      Project.find_each do |p|
        p.update_columns(category: Project.category_for(p.repo_path)) # rubocop:disable Rails/SkipsModelValidations
      end
    end
  end

  def down
    remove_index :projects, :category
    remove_column :projects, :category
  end
end
