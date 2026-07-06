namespace :stacks do
  desc "Backfill monthly P&L reports + line items for every QBO account (rollout, idempotent)"
  task backfill_monthly_pnl_line_items: :environment do
    QboAccount.all.each do |account|
      summary = Qbo::BackfillMonthlyProfitAndLossReports.call(qbo_account: account)
      puts "~~~> qbo_account=#{account.id} #{summary.inspect}"
    end
  end
end
