class Enterprise < ApplicationRecord
  has_one :qbo_account
  accepts_nested_attributes_for :qbo_account, allow_destroy: true
  VERTICAL_MATCHER = /\[(.+)\](.*)/

  def discover_verticals
    qbo_account.qbo_profit_and_loss_reports.reduce([]) do |acc, qbo_profit_and_loss_report|
      qbo_profit_and_loss_report.data["cash"]["rows"].each do |row|
        splat = /\[(.+)\](.*)/.match(row[0])
        acc |= [splat[1]] if splat.present?
      end
      acc
    end
  end

  def generate_snapshot!
    verticals = discover_verticals.map(&:to_sym)
    snapshot =
      [:year, :month, :quarter, :trailing_3_months, :trailing_4_months, :trailing_6_months, :trailing_12_months].reduce({
        generated_at: DateTime.now.iso8601,
      }) do |acc, gradation|
        periods = Stacks::Period.for_gradation(gradation, Date.new(2023, 1, 1))
        acc[gradation] = Parallel.map(periods, in_threads: 1) do |period|
          prev_period = periods[0] == period ? nil : periods[periods.index(period) - 1]

          verticals.reduce({
            label: period.label,
            period_starts_at: period.starts_at.strftime("%m/%d/%Y"),
            period_ends_at: period.ends_at.strftime("%m/%d/%Y"),
            verticals: {
              All: {
                cash: {
                  datapoints: self.key_datapoints_for_period(period, prev_period, "cash", :All)
                },
                accrual: {
                  datapoints: self.key_datapoints_for_period(period, prev_period, "accrual", :All)
                },
              }
            }
          }) do |acc, vertical|
            acc[:verticals][vertical] = {
              cash: {
                datapoints: self.key_datapoints_for_period(period, prev_period, "cash", vertical)
              },
              accrual: {
                datapoints: self.key_datapoints_for_period(period, prev_period, "accrual", vertical)
              },
            }
            acc
          end

        end
        acc
      end
    update!(snapshot: snapshot)
  end

  def key_datapoints_for_period(period, prev_period, accounting_method, vertical)
    data = period.report(self.qbo_account).data_for_enterprise(self, accounting_method, period.label, vertical)
    prev_data = 
      prev_period.report(self.qbo_account).data_for_enterprise(self, accounting_method, prev_period.label, vertical) if prev_period.present?

    {
      revenue: {
        value: data[:revenue],
        unit: :usd,
        growth: (prev_data ? ((data[:revenue].to_f / prev_data[:revenue].to_f) * 100) - 100 : nil)
      },
      cogs: {
        value: data[:cogs],
        unit: :usd
      },
      expenses: {
        value: data[:expenses],
        unit: :usd
      },
      profit_margin: {
        value: data[:profit_margin],
        unit: :percentage
      },
    }
  end
end
