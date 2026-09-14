class CreatePermissionGrants < ActiveRecord::Migration[6.1]
  def change
    create_table :permission_grants do |t|
      t.references :admin_user, null: false, foreign_key: true
      t.string :permission, null: false
      t.string :subject_type
      t.bigint :subject_id
      t.references :granted_by, foreign_key: { to_table: :admin_users }
      t.text :notes
      t.timestamps
    end

    add_index :permission_grants, [:subject_type, :subject_id]
    add_index :permission_grants, [:admin_user_id, :permission],
      unique: true,
      where: "subject_type IS NULL AND subject_id IS NULL",
      name: "index_permission_grants_unique_global"
    add_index :permission_grants, [:admin_user_id, :permission, :subject_type, :subject_id],
      unique: true,
      where: "subject_id IS NOT NULL",
      name: "index_permission_grants_unique_scoped"
  end
end
