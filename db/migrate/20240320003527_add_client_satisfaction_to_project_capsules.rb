class AddClientSatisfactionToProjectCapsules < ActiveRecord::Migration[6.0]
  def change
    add_column :project_capsules, :client_satisfaction_status, :integer
    add_column :project_capsules, :client_satisfaction_detail, :text
  end
end