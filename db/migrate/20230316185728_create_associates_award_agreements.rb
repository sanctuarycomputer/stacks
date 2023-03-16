class CreateAssociatesAwardAgreements < ActiveRecord::Migration[6.0]
  def change
    create_table :associates_award_agreements do |t|
      t.references :admin_user, null: false, foreign_key: true
      t.date :started_at, null: false
      t.integer :initial_unit_grant, null: false
      t.integer :vesting_unit_increments, null: false
      t.integer :vesting_periods, null: false
      t.integer :vesting_period_type, null: false, default: 0

      t.timestamps
    end
  end
end
