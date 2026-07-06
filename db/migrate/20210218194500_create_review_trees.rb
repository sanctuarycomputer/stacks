class CreateReviewTrees < ActiveRecord::Migration[6.0]
  def change
    create_table :review_trees do |t|
      t.references :review, null: false, foreign_key: true
      t.references :tree, null: false, foreign_key: true

      t.timestamps
    end
  end
end
