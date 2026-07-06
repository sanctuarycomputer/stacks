class CreateAdminUserInterests < ActiveRecord::Migration[6.0]
  def change
    create_table :admin_user_interests do |t|
      t.references :interest, null: false, foreign_key: true
      t.references :admin_user, null: false, foreign_key: true

      t.timestamps
    end
  end
end
