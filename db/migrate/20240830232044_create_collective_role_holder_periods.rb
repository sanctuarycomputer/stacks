class CreateCollectiveRoleHolderPeriods < ActiveRecord::Migration[6.0]
  def change
    create_table :collective_role_holder_periods do |t|
      t.references :collective_role, null: false, foreign_key: true
      t.references :admin_user, null: false, foreign_key: true

      t.date :started_at
      t.date :ended_at
      t.timestamps
    end
  end
end
