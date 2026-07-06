class CreateSystemTasks < ActiveRecord::Migration[6.0]
  def change
    create_table :system_tasks do |t|
      t.string :name, null: false
      t.datetime :settled_at
      t.references :notification, null: true, foreign_key: true

      t.timestamps
    end
  end
end
