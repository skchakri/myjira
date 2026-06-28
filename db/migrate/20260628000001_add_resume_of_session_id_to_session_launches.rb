class AddResumeOfSessionIdToSessionLaunches < ActiveRecord::Migration[8.1]
  def change
    add_column :session_launches, :resume_of_session_id, :string
  end
end
