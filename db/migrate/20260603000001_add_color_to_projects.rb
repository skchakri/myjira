class AddColorToProjects < ActiveRecord::Migration[8.1]
  def change
    # Folder accent colour (hex like "#2F6F4F"); null → deterministic default
    # picked from a palette by slug. Editable from the conversation cards.
    add_column :projects, :color, :string
  end
end
