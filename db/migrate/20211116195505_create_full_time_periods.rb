class CreateFullTimePeriods < ActiveRecord::Migration[6.0]
  def change
    create_table :full_time_periods do |t|
      t.references :admin_user, null: false, foreign_key: true
      t.date :started_at
      t.date :ended_at
      t.decimal :multiplier, default: 1.0

      t.timestamps
    end
  end
end
