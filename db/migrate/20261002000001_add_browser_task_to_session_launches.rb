class AddBrowserTaskToSessionLaunches < ActiveRecord::Migration[8.0]
  def change
    add_reference :session_launches, :browser_task, type: :uuid, foreign_key: true, index: true
  end
end
