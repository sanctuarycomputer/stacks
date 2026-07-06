class CreateStudioMemberships < ActiveRecord::Migration[6.0]
  def change
    create_table :studio_memberships do |t|
      t.references :admin_user, null: false, foreign_key: true
      t.references :studio, null: false, foreign_key: true

      t.timestamps
    end

    add_index :studio_memberships, [:admin_user_id, :studio_id], unique: true
  end
end
