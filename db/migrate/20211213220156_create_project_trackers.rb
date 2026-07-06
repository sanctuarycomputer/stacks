class CreateProjectTrackers < ActiveRecord::Migration[6.0]
  def change
    create_table :project_trackers do |t|
      t.string :name
      t.decimal :budget_low_end
      t.decimal :budget_high_end
      t.string :notion_project_url
      t.text :notes

      t.timestamps
    end
  end
end
