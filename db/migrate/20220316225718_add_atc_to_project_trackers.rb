class AddAtcToProjectTrackers < ActiveRecord::Migration[6.0]
  def change
    add_reference :project_trackers, :atc, foreign_key: { to_table: :admin_users }
  end
end
