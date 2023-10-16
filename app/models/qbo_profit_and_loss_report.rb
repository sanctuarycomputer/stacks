class QboProfitAndLossReport < ApplicationRecord
  belongs_to :qbo_account, optional: true
  
  def find_row(accounting_method, label)
    (data[accounting_method]["rows"].find {|r| r[0] == label } || [nil, 0])[1].to_f
  end

  def find_rows(accounting_method, labels_array=[])
    data[accounting_method]["rows"].select {|r| labels_array.include?(r[0]) }.reduce(0){|acc, row| acc += row[1].to_f}
  end

  def burn_rate(accounting_method)
    find_row(accounting_method, "Total Cost of Goods Sold") +
    find_row(accounting_method, "Total Expenses") -
    find_row(accounting_method, "[SC] Profit Share, Bonuses & Misc") -
    find_row(accounting_method, "[SC] Reinvestment")
  end

  def cogs_for_studio(studio, accounting_method, sellable_hours_proportion = nil)
    gross_revenue = find_rows(accounting_method, studio.qbo_sales_categories)

    # TODO: Include non-studio payroll & salary in COGS expenses
    # TODO: Deduct profit share & pre-spent/reinvestment from Studio OKRs
    proportional_expenses = 0
    if sellable_hours_proportion.present?
      # Studios are responsible for a proportion of total expenses based on their
      # own the size of their own sellable pool.
      proportional_expenses = 
        sellable_hours_proportion * find_row(accounting_method, "Total Expenses")
    else
      # In cases where we don't have sellable_hour pool data (predates our use of Forecast)
      # we fallback to splitting expenses based on how much revenue that studio brought in.
      # See Stacks::System::UTILIZATION_START_AT for more information
      # In any case, this is just a fallback; we don't actually surface this datapoint
      # anywhere that predates us having utilization data.
      g3d_gross_revenue = find_row(accounting_method, "Total Income")
      if g3d_gross_revenue > 0
        proportional_expenses =
          (gross_revenue / g3d_gross_revenue) * find_row(accounting_method, "Total Expenses")
      end
    end

    base = {
      revenue: gross_revenue,
      payroll: find_rows(accounting_method, studio.qbo_payroll_categories),
      benefits: find_rows(accounting_method, studio.qbo_benefits_categories),
      supplies: find_rows(accounting_method, studio.qbo_supplies_categories),
      expenses: proportional_expenses,
      subcontractors: find_rows(accounting_method, studio.qbo_subcontractors_categories),
      profit_share: find_row(accounting_method, "[SC] Profit Share, Bonuses & Misc"),
      reinvestment: find_row(accounting_method, "[SC] Reinvestment")
    }

    if studio.is_garden3d?
      base[:cogs] = (
        find_row(accounting_method, "Total Cost of Goods Sold") +
        base[:expenses] -
        find_row(accounting_method, "[SC] Profit Share, Bonuses & Misc") -
        find_row(accounting_method, "[SC] Reinvestment")
      )
    else
      base[:cogs] = (
        base[:payroll] +
        base[:supplies] +
        base[:benefits] +
        base[:expenses] +
        base[:subcontractors]
      )
    end

    base[:net_revenue] = base[:revenue] - base[:cogs]
    base[:profit_margin] = (base[:net_revenue] / base[:revenue]) * 100
    base
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
