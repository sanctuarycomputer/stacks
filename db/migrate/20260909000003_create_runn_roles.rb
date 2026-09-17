class CreateRunnRoles < ActiveRecord::Migration[6.1]
  def change
    create_table :runn_roles do |t|
      t.bigint :runn_id, null: false
      t.string :name
      t.decimal :standard_rate
      t.decimal :default_hour_cost
      t.boolean :is_archived, null: false, default: false
      t.datetime :created_at
      t.datetime :updated_at
      t.jsonb :data
    end
    add_index :runn_roles, :runn_id, unique: true
  end
end
