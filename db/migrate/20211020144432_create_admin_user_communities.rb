class CreateAdminUserCommunities < ActiveRecord::Migration[6.0]
  def change
    create_table :admin_user_communities do |t|
      t.references :community, null: false, foreign_key: true
      t.references :admin_user, null: false, foreign_key: true

      t.timestamps
    end
  end
end
