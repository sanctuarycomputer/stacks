class QboProfitAndLossReport < ApplicationRecord
  belongs_to :qbo_account, optional: true

  TOP_LEVEL_CATEGORIES = {
    revenue: "Total Income",
    cogs: "Total Cost of Goods Sold",
    expenses: "Total Expenses"
  }

  def find_row(accounting_method, label)
    (data[accounting_method]["rows"].find {|r| r[0] == label } || [nil, 0])[1].to_f
  end

  def find_rows(accounting_method, labels_array=[])
    data[accounting_method]["rows"].select {|r| labels_array.include?(r[0]) }.reduce(0){|acc, row| acc += row[1].to_f}
  end

  def expenses_by_studio(studios = Studio.all, accounting_method)
    expense_data = studios.reduce({}) do |acc, studio|
      acc[studio] = []
      acc
    end

    expense_rows_start_at = data[accounting_method]["rows"].find_index(["Expenses", nil])
    return expense_data if expense_rows_start_at.nil?

    # Grab the range between Expense header & footer
    expense_rows = data[accounting_method]["rows"].drop(expense_rows_start_at + 1)
    expense_rows = expense_rows.take(expense_rows.find_index{|r| r[0] == "Total Expenses"})

    # Remove section headers w/ no top-level value
    expense_rows = expense_rows.reject{|r| r[1].nil? }
    # Remove section footers (no need for totals in this report)
    expense_rows = expense_rows.reject{|r| r[0].starts_with?("Total") }

    expense_data.each do |studio, studio_expense_rows|
      if studio.is_garden3d?
        # Take all expenses that don't match a studio
        expense_data[studio] = expense_rows.select do |row|
          expense_row_belongs_to_studio =
            studios.map(&:accounting_prefix).select(&:present?).any?{|p| row[0].starts_with?("[SC] #{p}")}
          !expense_row_belongs_to_studio
        end
      else
        # Take expenses that match the studio
        expense_data[studio] = expense_rows.select do |row|
          row[0].starts_with?("[SC] #{studio.accounting_prefix}")
        end
      end
    end
    expense_data
  end

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

  def cogs_for_studio(
    studio,
    preloaded_studios,
    accounting_method,
    period_label,
    sellable_hours_proportion = nil
  )
    gross_revenue = find_rows(accounting_method, studio.qbo_sales_categories)

    # TODO: Include internal studio payroll (UBS) & salary & expenses in COGS expenses
    divided_expenses = expenses_by_studio(preloaded_studios, accounting_method)
    specified_expenses = divided_expenses[studio].reduce(0){|acc, e| acc += e[1].to_f}

    total_internal_cost =
      Studio.internal.reduce(0) do |acc, studio|
        snapshot_period = studio.snapshot.map{|k, v| v}.flatten.find{|p| p["label"] == period_label} || {}
        net_revenue = snapshot_period.dig(accounting_method, "datapoints", "net_revenue", "value").try(:to_f) || 0
        acc += net_revenue.abs if net_revenue < 0
        acc
      end

    expense_map =
      if studio.is_garden3d?
        {
          total: find_row(accounting_method, "Total Expenses"),
          specific: find_row(accounting_method, "Total Expenses") - specified_expenses, # for g3d, expenses w a studio
          unspecified_split: specified_expenses, # for g3d, expenses w/o a studio
          internal_split: total_internal_cost
        }
      else
        g3d = preloaded_studios.find(&:is_garden3d?)
        unspecified_expenses = divided_expenses[g3d].reduce(0){|acc, e| acc += e[1].to_f}
        unspecified_split_expenses = 0
        internal_split_cost = 0
        if sellable_hours_proportion.present?
          # Studios are responsible for a proportion of total expenses based on their
          # own the size of their own sellable pool.
          unspecified_split_expenses =
            sellable_hours_proportion * unspecified_expenses
          internal_split_cost =
            sellable_hours_proportion * total_internal_cost
        else
          # In cases where we don't have sellable_hour pool data (predates our use of Forecast)
          # we fallback to splitting expenses based on how much revenue that studio brought in.
          # See Stacks::System::UTILIZATION_START_AT for more information
          # In any case, this is just a fallback; we don't actually surface this datapoint
          # anywhere that predates us having utilization data.
          g3d_gross_revenue = find_row(accounting_method, "Total Income")
          if g3d_gross_revenue > 0
            unspecified_split_expenses =
              (gross_revenue / g3d_gross_revenue) * unspecified_expenses
            internal_split_cost =
              (gross_revenue / g3d_gross_revenue) * total_internal_cost
          end
        end

        {
          total: (unspecified_split_expenses + specified_expenses + internal_split_cost),
          specific: specified_expenses, # for studios, expenses under a studio tag
          unspecified_split: unspecified_split_expenses, # for studios, expenses w/o a studio tag, split proportionally
          internal_split: internal_split_cost
        }
      end

    base = {
      revenue: gross_revenue,
      payroll: find_rows(accounting_method, studio.qbo_payroll_categories),
      bonuses: find_rows(accounting_method, studio.qbo_bonus_categories),
      benefits: find_rows(accounting_method, studio.qbo_benefits_categories),
      supplies: find_rows(accounting_method, studio.qbo_supplies_categories),
      expenses: expense_map,
      subcontractors: find_rows(accounting_method, studio.qbo_subcontractors_categories)
    }

    scenarios = [base]

    # For garden3d, make a second scenario with the reinvestment numbers excluded
    if studio.is_garden3d?
      aggregated_reinvestment_cogs =
        Studio.reinvestment.reduce({
          revenue: 0,
          payroll: 0,
          bonuses: 0,
          benefits: 0,
          supplies: 0,
          expenses: {
            total: 0,
            specific: 0,
            unspecified_split: 0,
            internal_split: 0
          },
          subcontractors: 0
        }) do |acc, studio|
          snapshot_period = studio.snapshot.map{|k, v| v}.flatten.find{|p| p["label"] == period_label} || {}

          acc[:revenue] += snapshot_period.dig(accounting_method, "datapoints", "revenue", "value").try(:to_f) || 0
          acc[:payroll] += snapshot_period.dig(accounting_method, "datapoints", "payroll", "value").try(:to_f) || 0
          acc[:bonuses] += snapshot_period.dig(accounting_method, "datapoints", "bonuses", "value").try(:to_f) || 0
          acc[:benefits] += snapshot_period.dig(accounting_method, "datapoints", "benefits", "value").try(:to_f) || 0
          acc[:supplies] += snapshot_period.dig(accounting_method, "datapoints", "supplies", "value").try(:to_f) || 0

          acc[:expenses][:total] += snapshot_period.dig(accounting_method, "datapoints", "total_expenses", "value").try(:to_f) || 0
          acc[:expenses][:specific] += snapshot_period.dig(accounting_method, "datapoints", "specific_expenses", "value").try(:to_f) || 0
          acc[:expenses][:unspecified_split] += snapshot_period.dig(accounting_method, "datapoints", "unspecified_split_expenses", "value").try(:to_f) || 0
          acc[:expenses][:internal_split] += snapshot_period.dig(accounting_method, "datapoints", "internal_split_expenses", "value").try(:to_f) || 0

          acc[:subcontractors] += snapshot_period.dig(accounting_method, "datapoints", "subcontractors", "value").try(:to_f) || 0
          acc
        end

      scenarios = [*scenarios, {
        revenue: base[:revenue] - aggregated_reinvestment_cogs[:revenue],
        payroll: base[:payroll] - aggregated_reinvestment_cogs[:payroll],
        bonuses: base[:bonuses] - aggregated_reinvestment_cogs[:bonuses],
        benefits: base[:benefits] - aggregated_reinvestment_cogs[:benefits],
        supplies: base[:supplies] - aggregated_reinvestment_cogs[:supplies],
        expenses: {
          total: base[:expenses][:total] - aggregated_reinvestment_cogs[:expenses][:total],
          specific: base[:expenses][:specific] - aggregated_reinvestment_cogs[:expenses][:specific],
          unspecified_split: base[:expenses][:unspecified_split] - aggregated_reinvestment_cogs[:expenses][:unspecified_split],
          internal_split: base[:expenses][:internal_split] - aggregated_reinvestment_cogs[:expenses][:internal_split]
        },
        subcontractors: base[:subcontractors] - aggregated_reinvestment_cogs[:subcontractors]
      }]
    end

    # Calc COGS, net_revenue, profit_margin for each scenario
    scenarios.each do |s|
      s[:cogs] = (
        s[:payroll] +
        s[:bonuses] +
        s[:supplies] +
        s[:benefits] +
        s[:subcontractors] +
        s[:expenses][:total]
      )
      s[:net_revenue] = s[:revenue] - s[:cogs]
      s[:profit_margin] = (s[:net_revenue] / s[:revenue]) * 100
    end

    scenarios
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
