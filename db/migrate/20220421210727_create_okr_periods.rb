class CreateOkrPeriods < ActiveRecord::Migration[6.0]
  def change
    create_table :okr_periods do |t|
      t.references :okr, null: false, foreign_key: true
      t.date :starts_at
      t.date :ends_at
      t.decimal :target, null: false
      t.decimal :tolerance, null: false

      t.timestamps
    end
  end
end
