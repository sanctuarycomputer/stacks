class BackfillQboProfitAndLossReportsQboAccountId < ActiveRecord::Migration[6.1]
  def up
    sanctuary_qa = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME).qbo_account
    raise "Sanctuary has no qbo_account" if sanctuary_qa.nil?
    execute "UPDATE qbo_profit_and_loss_reports SET qbo_account_id = #{sanctuary_qa.id} WHERE qbo_account_id IS NULL"
    change_column_null :qbo_profit_and_loss_reports, :qbo_account_id, false
  end

  def down
    change_column_null :qbo_profit_and_loss_reports, :qbo_account_id, true
  end
end
