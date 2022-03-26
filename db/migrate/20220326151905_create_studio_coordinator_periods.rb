class CreateStudioCoordinatorPeriods < ActiveRecord::Migration[6.0]
  def change
    create_table :studio_coordinator_periods do |t|
      t.references :studio, null: false, foreign_key: true
      t.references :admin_user, null: false, foreign_key: true
      t.date :started_at, null: false
      t.date :ended_at

      t.timestamps
    end
  end
end
