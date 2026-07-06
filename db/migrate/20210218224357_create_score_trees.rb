class CreateScoreTrees < ActiveRecord::Migration[6.0]
  def change
    create_table :score_trees do |t|
      t.references :tree, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true

      t.timestamps
    end
  end
end
