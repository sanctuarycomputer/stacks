class CreatePeerReviews < ActiveRecord::Migration[6.0]
  def change
    create_table :peer_reviews do |t|
      t.references :admin_user, null: false, foreign_key: true
      t.references :review, null: false, foreign_key: true

      t.timestamps
    end
  end
end
