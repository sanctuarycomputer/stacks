class CreateAdminUserAcknowledgements < ActiveRecord::Migration[6.0]
  def change
    create_table :admin_user_acknowledgements do |t|
      t.references :acknowledgement, null: false, foreign_key: true
      t.references :admin_user, null: false, foreign_key: true

      t.timestamps
    end
  end
end
