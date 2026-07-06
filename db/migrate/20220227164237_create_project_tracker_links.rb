class CreateProjectTrackerLinks < ActiveRecord::Migration[6.0]
  def change
    create_table :project_tracker_links do |t|
      t.string :name, null: false
      t.string :url, null: false
      t.integer :link_type, default: 0
      t.references :project_tracker, null: false, foreign_key: true

      t.timestamps
    end
  end
end
