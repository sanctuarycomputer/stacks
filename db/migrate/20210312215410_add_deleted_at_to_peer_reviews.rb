class AddDeletedAtToPeerReviews < ActiveRecord::Migration[6.0]
  def change
    add_column :peer_reviews, :deleted_at, :datetime
    add_index :peer_reviews, :deleted_at
  end
end
