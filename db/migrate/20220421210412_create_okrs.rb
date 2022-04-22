class CreateOkrs < ActiveRecord::Migration[6.0]
  def change
    create_table :okrs do |t|
      t.string :name, null: false
      t.text :description
      t.integer :operator, default: 0
      t.integer :datapoint, default: 0

      t.timestamps
    end
  end
end
