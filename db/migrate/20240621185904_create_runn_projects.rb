class CreateRunnProjects < ActiveRecord::Migration[6.0]
  def change
    create_table :runn_projects do |t|
      t.bigint :runn_id
      t.string :name
      t.boolean :is_template
      t.boolean :is_archived
      t.boolean :is_confirmed
      t.string :pricing_model
      t.string :rate_type
      t.integer :budget
      t.integer :expenses_budget
      t.datetime :created_at
      t.datetime :updated_at
      t.jsonb :data
    end

    add_index :runn_projects, :runn_id, unique: true
  end
end
