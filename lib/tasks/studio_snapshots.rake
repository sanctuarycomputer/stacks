namespace :stacks do
  desc "Backfill monthly P&L reports + line items for every QBO account (rollout, idempotent)"
  task backfill_monthly_pnl_line_items: :environment do
    QboAccount.all.each do |account|
      summary = Qbo::BackfillMonthlyProfitAndLossReports.call(qbo_account: account)
      puts "~~~> qbo_account=#{account.id} #{summary.inspect}"
    end
  end

  desc "Diff live GradationRows output against every studio's stored snapshot blob"
  task studio_snapshot_oracle: :environment do
    Studio.all.each do |studio|
      result = Studios::Snapshots::DiffAgainstStored.call(studio: studio)
      status = result.mismatches.empty? ? "CLEAN" : "#{result.mismatches.length} MISMATCHES"
      puts "~~~> #{studio.mini_name}: checked=#{result.checked} #{status}"
      result.mismatches.first(100).each { |m| puts "     #{m}" }
    end
  end

  desc "Verify monthly line items reproduce stored range reports (additivity check)"
  task pnl_additivity_check: :environment do
    account = Enterprise.sanctuary.qbo_account
    mismatches = 0
    QboProfitAndLossReport.where(qbo_account: account).find_each do |report|
      # Skip monthly rows — they ARE the line-item source.
      next if report.starts_at == report.starts_at.beginning_of_month &&
              report.ends_at == report.starts_at.end_of_month

      %w[cash accrual].each do |method|
        row = (report.data.dig(method, "rows") || []).find { |r| r[0] == "Total Income" }
        next if row.nil?
        stored = row[1].to_f
        summed = QboProfitAndLossLineItem.where(
          qbo_account: account,
          accounting_method: method,
          label: "Total Income",
          starts_at: report.starts_at..report.ends_at
        ).sum(:amount).to_f
        next if (stored - summed).abs <= 0.01
        mismatches += 1
        puts "MISMATCH #{report.starts_at}..#{report.ends_at} #{method}: stored=#{stored} summed=#{summed}"
      end
    end
    puts mismatches.zero? ? "~~~> additivity CLEAN" : "~~~> #{mismatches} additivity mismatches"
  end
end
