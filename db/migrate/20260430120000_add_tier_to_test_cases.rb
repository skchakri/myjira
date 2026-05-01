class AddTierToTestCases < ActiveRecord::Migration[8.0]
  def change
    add_column :test_cases, :tier, :string, null: false, default: "acceptance"
    add_index :test_cases, :tier
  end
end
