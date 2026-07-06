class CreateAdminUserRacialBackgrounds < ActiveRecord::Migration[6.0]
  def change
    create_table :admin_user_racial_backgrounds do |t|
      t.references :racial_background, null: false, foreign_key: true
      t.references :admin_user, null: false, foreign_key: true

      t.timestamps
    end
  end
end
