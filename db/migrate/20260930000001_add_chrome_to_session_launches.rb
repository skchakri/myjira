class AddChromeToSessionLaunches < ActiveRecord::Migration[8.0]
  def change
    add_column :session_launches, :chrome, :boolean, default: false, null: false
  end
end
