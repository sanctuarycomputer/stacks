class QboProfitAndLossReport < ApplicationRecord
  def find_row(label)
    (data["rows"].find {|r| r[0] == label } || [nil, 0])[1].to_f
  end

  def burn_rate
    find_row("Total Cost of Goods Sold") +
    find_row("Total Expenses") -
    find_row("[SC] Profit Share, Bonuses & Misc") -
    find_row("[SC] Reinvestment")
  end

  def cogs_for_studio(studio)
    gross_revenue = find_row(studio.qbo_sales_category)
    g3d_gross_revenue = find_row("Total Income")

    proportional_expenses = 0
    if g3d_gross_revenue > 0
      proportional_expenses =
        (gross_revenue / g3d_gross_revenue) * find_row("Total Expenses")
    end

    base = {
      revenue: gross_revenue,
      payroll: find_row(studio.qbo_payroll_category),
      benefits: find_row(studio.qbo_benefits_category),
      supplies: find_row(studio.qbo_supplies_category),
      expenses: proportional_expenses,
      subcontractors: find_row(studio.qbo_subcontractors_category),
      profit_share: find_row("[SC] Profit Share, Bonuses & Misc"),
      reinvestment: find_row("[SC] Reinvestment")
    }

    if studio.is_garden3d?
      base[:cogs] = (
        find_row("Total Cost of Goods Sold") +
        base[:expenses] -
        find_row("[SC] Profit Share, Bonuses & Misc") -
        find_row("[SC] Reinvestment")
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

  def self.find_or_fetch_for_range(start_of_range, end_of_range, force = false)
    ActiveRecord::Base.transaction do
      existing = where(starts_at: start_of_range, ends_at: end_of_range)
      if force
        existing.delete_all
      else
        return existing.first if existing.any?
      end

      report = Stacks::Quickbooks.fetch_profit_and_loss_report_for_range(
        start_of_range,
        end_of_range
      )

      create!(
        starts_at: start_of_range,
        ends_at: end_of_range,
        data: { rows: report.all_rows }
      )
    end
  end
end
