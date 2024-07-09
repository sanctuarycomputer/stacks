class AddRunnProjectToProjectTrackers < ActiveRecord::Migration[6.0]
  def change
    add_reference :project_trackers, :runn_project, foreign_key: { to_table: :runn_projects, primary_key: "runn_id" }
  end
end