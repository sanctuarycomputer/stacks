class CreateAdminUserCulturalBackgrounds < ActiveRecord::Migration[6.0]
  def change
    create_table :admin_user_cultural_backgrounds do |t|
      t.references :cultural_background, null: false, foreign_key: true
      t.references :admin_user, null: false, foreign_key: true

      t.timestamps
    end
  end
end
