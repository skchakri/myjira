class CreateJiraConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :jira_connections, id: :uuid do |t|
      t.string :site_url
      t.string :email
      t.text   :api_token   # encrypted at rest via ActiveRecord::Encryption
      t.timestamps
    end
  end
end
