class AddArchivedAtToReviews < ActiveRecord::Migration[6.0]
  def change
    add_column :reviews, :archived_at, :datetime
  end
end
