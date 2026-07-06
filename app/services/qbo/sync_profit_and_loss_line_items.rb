module Qbo
  # Projects a MONTHLY QboProfitAndLossReport's jsonb rows into
  # qbo_profit_and_loss_line_items so studio datapoints can be computed with
  # SQL instead of Ruby row-walking. Idempotent: replaces the report's rows
  # in one transaction. Non-monthly reports are skipped — the monthly grain
  # is the fact table; wider ranges are folded from months at read time.
  class SyncProfitAndLossLineItems
    def self.call(report)
      return :not_monthly unless monthly?(report)

      # A freshly create!'d report still holds symbol keys in memory;
      # persisted jsonb reads back with string keys. Cope with both.
      data = report.data || {}
      now = Time.current
      rows = []
      %w[cash accrual].each do |method|
        source_rows = data.dig(method, "rows") || data.dig(method.to_sym, :rows) || []
        source_rows.each_with_index do |row, position|
          label, amount = row[0], row[1]
          next if label.nil?
          rows << {
            qbo_account_id: report.qbo_account_id,
            qbo_profit_and_loss_report_id: report.id,
            starts_at: report.starts_at,
            accounting_method: method,
            position: position,
            label: label,
            amount: amount.to_f, # find_row does r[1].to_f — nil → 0.0
            created_at: now,
            updated_at: now,
          }
        end
      end

      ActiveRecord::Base.transaction do
        QboProfitAndLossLineItem
          .where(qbo_profit_and_loss_report_id: report.id)
          .delete_all
        QboProfitAndLossLineItem.insert_all!(rows) if rows.any?
      end
      :synced
    end

    def self.monthly?(report)
      report.starts_at == report.starts_at.beginning_of_month &&
        report.ends_at == report.starts_at.end_of_month
    end
  end
end
