class CreateFinalizations < ActiveRecord::Migration[6.0]
  def change
    create_table :finalizations do |t|
      t.references :review, null: false, foreign_key: true

      t.timestamps
    end
  end
end
