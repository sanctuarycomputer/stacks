class CreatePeriodicReports < ActiveRecord::Migration[6.1]
  def change
    create_table :periodic_reports do |t|
      t.integer :period_gradation, null: false, default: 0
      t.date :period_starts_at, null: false
      t.string :period_label, null: false
      t.jsonb :blueprint, null: false, default: {}

      t.timestamps
    end

    add_index :periodic_reports, [:period_gradation, :period_starts_at], unique: true
  end
end
