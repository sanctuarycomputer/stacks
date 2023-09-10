class CreateEnterprises < ActiveRecord::Migration[6.0]
  def change
    create_table :enterprises do |t|
      t.string :name, null: false
      t.jsonb :snapshot, default: {}

      t.timestamps
    end
  end
end
