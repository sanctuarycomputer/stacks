class CreateScores < ActiveRecord::Migration[6.0]
  def change
    create_table :scores do |t|
      t.references :trait, null: false, foreign_key: true
      t.references :score_tree, null: false, foreign_key: true
      t.integer :band
      t.integer :consistency

      t.timestamps
    end
  end
end
