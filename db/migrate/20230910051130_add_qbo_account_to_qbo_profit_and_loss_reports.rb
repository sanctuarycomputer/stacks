class AddQboAccountToQboProfitAndLossReports < ActiveRecord::Migration[6.0]
  def change
    add_reference :qbo_profit_and_loss_reports, :qbo_account, foreign_key: true
  end
end
