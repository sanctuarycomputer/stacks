class CreateAdminUserGenderIdentities < ActiveRecord::Migration[6.0]
  def change
    create_table :admin_user_gender_identities do |t|
      t.references :gender_identity, null: false, foreign_key: true
      t.references :admin_user, null: false, foreign_key: true

      t.timestamps
    end
  end
end
