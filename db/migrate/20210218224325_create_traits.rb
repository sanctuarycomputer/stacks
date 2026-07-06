class CreateTraits < ActiveRecord::Migration[6.0]
  def change
    create_table :traits do |t|
      t.references :tree, null: false, foreign_key: true
      t.string :name

      t.timestamps
    end
  end
end
