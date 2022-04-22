class CreateOkrPeriodStudios < ActiveRecord::Migration[6.0]
  def change
    create_table :okr_period_studios do |t|
      t.references :studio, null: false, foreign_key: true
      t.references :okr_period, null: false, foreign_key: true

      t.timestamps
    end
  end
end
