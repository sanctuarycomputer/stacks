class CreateQboProfitAndLossReports < ActiveRecord::Migration[6.0]
  def change
    create_table :qbo_profit_and_loss_reports do |t|
      t.date :starts_at, null: false
      t.date :ends_at, null: false
      t.jsonb :data, default: '{}'

      t.timestamps
    end
  end
end
