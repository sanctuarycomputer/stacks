class QboProfitAndLossReport < ApplicationRecord
  belongs_to :qbo_account, optional: true

  TOP_LEVEL_CATEGORIES = {
    revenue: "Total Income",
    cogs: "Total Cost of Goods Sold",
    expenses: "Total Expenses"
  }

  def find_row(accounting_method, label = "")
    if block_given?
      (data[accounting_method]["rows"].find {|r| yield(r) } || [nil, 0])[1].to_f
    else
      (data[accounting_method]["rows"].find {|r| r[0] == label } || [nil, 0])[1].to_f
    end
  end

  def find_rows(accounting_method, labels_array=[])
    data[accounting_method]["rows"].select {|r| labels_array.include?(r[0]) }.reduce(0){|acc, row| acc += row[1].to_f}
  end

  # TODO: Refactor me to the Enterprise model
  def data_for_enterprise(enterprise, accounting_method, period_label, vertical)
    if vertical == :All
      dataset =
        {
          revenue: find_rows(accounting_method, "Total Income"),
          cogs: find_rows(accounting_method, "Total Cost of Goods Sold"),
          expenses: find_rows(accounting_method, "Total Expenses"),
          net_revenue: find_rows(accounting_method, "Net Income"),
          profit_margin: 0
        }
      ((dataset[:net_revenue] / dataset[:revenue]) * 100) if dataset[:revenue] > 0
      return dataset
    end

    dataset =
      data[accounting_method]["rows"].reduce({
        revenue: 0,
        cogs: 0,
        expenses: 0,
        net_revenue: 0,
        profit_margin: 0
      }) do |acc, row|
        splat = Enterprise::VERTICAL_MATCHER.match(row[0])
        next acc unless splat.present?
        next acc unless splat[1].to_sym == vertical
        idx = data[accounting_method]["rows"].index(row)
        top_level_category_row =
          data[accounting_method]["rows"][idx..].find{|r| TOP_LEVEL_CATEGORIES.values.include?(r[0])}
        acc[TOP_LEVEL_CATEGORIES.key(top_level_category_row[0])] += row[1].to_f
        acc
      end

      dataset[:net_revenue] = dataset[:revenue] - dataset[:cogs] - dataset[:expenses]
    ((dataset[:net_revenue] / dataset[:revenue]) * 100) if dataset[:revenue] > 0
    dataset
  end

  def self.find_or_fetch_for_range(start_of_range, end_of_range, force = false, qbo_account = nil)
    ActiveRecord::Base.transaction do
      existing = where(starts_at: start_of_range, ends_at: end_of_range, qbo_account: qbo_account)
      if force
        existing.delete_all
      else
        return existing.first if existing.any?
      end

      cash_report = if qbo_account.present?
        qbo_account.fetch_profit_and_loss_report_for_range(
          start_of_range,
          end_of_range,
          "Cash"
        )
      else
        Stacks::Quickbooks.fetch_profit_and_loss_report_for_range(
          start_of_range,
          end_of_range,
          "Cash"
        )
      end

      accrual_report = if qbo_account.present?
        qbo_account.fetch_profit_and_loss_report_for_range(
          start_of_range,
          end_of_range,
          "Accrual"
        )
      else
        Stacks::Quickbooks.fetch_profit_and_loss_report_for_range(
          start_of_range,
          end_of_range,
          "Accrual"
        )
      end

      create!(
        qbo_account: qbo_account,
        starts_at: start_of_range,
        ends_at: end_of_range,
        data: {
          cash: { rows: cash_report.all_rows },
          accrual: { rows: accrual_report.all_rows }
        }
      )
    end
  end
end
