class Enterprise < ApplicationRecord
  has_one :qbo_account
  accepts_nested_attributes_for :qbo_account, allow_destroy: true

  VERTICAL_MATCHER = /\[(.+)\](.*)/

  # Is the programming business profitable?
  # Is the desk/rental business profitable?
  # Is the online course business profitable?
  # TODO: Setup Shopify <> QBO
  # TODO: Setup Deel <> QBO
  # TODO: Look into Patreon, Optix <> QBO

  def discover_verticals
    qbo_account.qbo_profit_and_loss_reports.reduce([]) do |acc, qbo_profit_and_loss_report|
      qbo_profit_and_loss_report.data["cash"]["rows"].each do |row|
        puts row[0]
        splat = /\[(.+)\](.*)/.match(row[0])
        acc |= [splat[1]] if splat.present?
      end
      acc
    end
  end

  def generate_snapshot!
    snapshot =
      [:year, :month, :quarter, :trailing_3_months, :trailing_4_months, :trailing_6_months, :trailing_12_months].reduce({
        generated_at: DateTime.now.iso8601,
      }) do |acc, gradation|
        periods = Stacks::Period.for_gradation(gradation, Date.new(2023, 1, 1))
        acc[gradation] = Parallel.map(periods, in_threads: 5) do |period|
          prev_period = periods[0] == period ? nil : periods[periods.index(period) - 1]

          {
            label: period.label,
            period_starts_at: period.starts_at.strftime("%m/%d/%Y"),
            period_ends_at: period.ends_at.strftime("%m/%d/%Y"),
            cash: {
              datapoints: self.key_datapoints_for_period(period, prev_period, "cash")
            },
            accrual: {
              datapoints: self.key_datapoints_for_period(period, prev_period, "accrual")
            },
          }
        end
        acc
      end
    update!(snapshot: snapshot)
  end

  def key_datapoints_for_period(period, prev_period, accounting_method)
    cogs = period.report(self.qbo_account).data_for_enterprise(self, accounting_method, period.label)
    prev_cogs = prev_period.report(self.qbo_account).data_for_enterprise(self, accounting_method, prev_period.label) if prev_period.present?

    data = {
      revenue: {
        value: cogs[:revenue],
        unit: :usd,
        growth: (prev_cogs ? ((cogs[:revenue].to_f / prev_cogs[:revenue].to_f) * 100) - 100 : nil)
      }
    }
    data
  end
end
