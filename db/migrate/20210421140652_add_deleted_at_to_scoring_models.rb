class AddDeletedAtToScoringModels < ActiveRecord::Migration[6.0]
  def change
    add_column :finalizations, :deleted_at, :datetime
    add_index :finalizations, :deleted_at

    add_column :scores, :deleted_at, :datetime
    add_index :scores, :deleted_at

    add_column :score_trees, :deleted_at, :datetime
    add_index :score_trees, :deleted_at

    add_column :workspaces, :deleted_at, :datetime
    add_index :workspaces, :deleted_at

    add_column :review_trees, :deleted_at, :datetime
    add_index :review_trees, :deleted_at
  end
end
