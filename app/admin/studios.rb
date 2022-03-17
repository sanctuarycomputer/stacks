ActiveAdmin.register Studio do
  config.filters = false
  config.paginate = false
  actions :index, :show, :edit, :update

  permit_params :name, :accounting_prefix, :mini_name

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.input :name
      f.input :accounting_prefix
      f.input :mini_name
    end
    f.actions
  end

  index download_links: false do
    column :name
    column :accounting_prefix
    column :mini_name
    actions
  end

  show do
    COLORS = Stacks::Utils::COLORS

    all_gradations = ["month", "quarter", "year"]
    default_gradation = "month"
    current_gradation =
      params["gradation"] || default_gradation
    current_gradation =
      default_gradation unless all_gradations.include?(current_gradation)

    periods = []
    time = Date.new(2020, 1, 1)
    case current_gradation
    when nil
    when "month"
      while time < Date.today.last_month.end_of_month
        periods << {
          label: time.strftime("%B, %Y"),
          starts_at: time.beginning_of_month,
          ends_at: time.end_of_month
        }
        time = time.advance(months: 1)
      end
    when "quarter"
      while time < Date.today.last_quarter.end_of_quarter
        periods << {
          label: "Q#{(time.beginning_of_quarter.month / 3) + 1}, #{time.beginning_of_quarter.year}",
          starts_at: time.beginning_of_quarter,
          ends_at: time.end_of_quarter
        }
        time = time.advance(months: 3)
      end
    when "year"
      while time < Date.today.last_year.end_of_year
        periods << {
          label: "#{time.beginning_of_quarter.year}",
          starts_at: time.beginning_of_year,
          ends_at: time.end_of_year
        }
        time = time.advance(years: 1)
      end
    end

    studio_profitability_data = {
      labels: periods.map{|p| p[:label]},
      datasets: [
        { label: "Profit Margin (%)", data: [], yAxisID: 'y1', type: 'line'},
        { label: "Payroll", data: [], backgroundColor: COLORS[1], stack: 'cogs' },
        { label: "Benefits", data: [], backgroundColor: COLORS[2], stack: 'cogs' },
        { label: "Expenses", data: [], backgroundColor: COLORS[3], stack: 'cogs' },
        { label: "Subcontractors", data: [], backgroundColor: COLORS[4], stack: 'cogs' },
        { label: "Revenue", data: [], backgroundColor: COLORS[0] },
      ]
    }

    periods.each do |p|
      report =
        QboProfitAndLossReport.find_or_fetch_for_range(p[:starts_at], p[:ends_at])

      gross_revenue =
        report.find_row(resource.qbo_sales_category)[1].to_f
      g3d_gross_revenue =
        report.find_row("Total Income")[1].to_f
      proportional_expenses = 0
      if g3d_gross_revenue > 0
        proportional_expenses =
          (gross_revenue / g3d_gross_revenue) * report.find_row("Total Expenses")[1].to_f
      end

      # Revenue
      ds = studio_profitability_data[:datasets].find{|d| d[:label] == "Revenue"}
      ds[:data] << gross_revenue

      # Payroll
      ds = studio_profitability_data[:datasets].find{|d| d[:label] == "Payroll"}
      ds[:data] << report.find_row(resource.qbo_payroll_category)[1].to_f

      # Benefits
      ds = studio_profitability_data[:datasets].find{|d| d[:label] == "Benefits"}
      ds[:data] << report.find_row(resource.qbo_benefits_category)[1].to_f

      # Expenses
      ds = studio_profitability_data[:datasets].find{|d| d[:label] == "Expenses"}
      ds[:data] << proportional_expenses

      # Subcontractors
      ds = studio_profitability_data[:datasets].find{|d| d[:label] == "Subcontractors"}
      ds[:data] << report.find_row(resource.qbo_subcontractors_category)[1].to_f

      # Margin
      ds = studio_profitability_data[:datasets].find{|d| d[:label] == "Profit Margin (%)"}
      net_revenue =
        gross_revenue - (
          report.find_row(resource.qbo_payroll_category)[1].to_f +
          report.find_row(resource.qbo_benefits_category)[1].to_f +
          proportional_expenses +
          report.find_row(resource.qbo_subcontractors_category)[1].to_f
        )
      ds[:data] <<
        (net_revenue / gross_revenue) * 100
    end

    all_studios = Studio.all
    studio_people =
      ForecastPerson.includes(:admin_user).all.select do |fp|
        fp.studio(all_studios) == resource
      end.reduce({}) do |acc, fp|
        acc[fp] = periods.reduce({}) do |agr, period|
          next agr if (
            period[:starts_at] < Stacks::System.singleton_class::UTILIZATION_START_AT
          )
          agr[period[:label]] = fp.utilization_during_range(
            period[:starts_at],
            period[:ends_at]
          )

          if fp.admin_user.present?
            working_days = fp.admin_user.working_days_between(
              period[:starts_at],
              period[:ends_at],
            ).count
            sellable_hours = (working_days * fp.admin_user.expected_utilization * 8)
            non_sellable_hours = (working_days * 8) - sellable_hours
            agr[period[:label]] = agr[period[:label]].merge({
              sellable: sellable_hours,
              non_sellable: non_sellable_hours
            })
          end

          agr
        end
        acc
      end

    # TODO: Should we be including Time Off for 4-day workers
    # in the Time Off count?
    aggregated_data =
      studio_people.values.reduce({}) do |acc, periods|
        periods.each do |label, data|
          next acc[label] = data unless acc[label].present?
          acc[label] = acc[label].merge(data) do |k, old, new|
            old.is_a?(Hash) ? old.merge(new) {|k, o, n| o+n} : old + new
          end
        end
        acc
      end

    studio_utilization_data = {
      labels: aggregated_data.keys,
      datasets: []
    }

    studio_utilization_data[:datasets].concat([{
      label: 'Utilization Rate (%)',
      borderColor: COLORS[4],
      data: (aggregated_data.values.map do |v|
        total_billable = v[:billable].values.reduce(&:+)
        next 0 if total_billable.nil? || v[:sellable].nil?
        (total_billable / v[:sellable]) * 100
      end),
      yAxisID: 'y2',
    }, {
      label: 'Actual Hours Sold',
      backgroundColor: COLORS[8],
      data: (aggregated_data.values.map do |v|
        v[:billable].values.reduce(&:+)
      end),
      yAxisID: 'y1',
      type: 'bar',
      stack: 'Stack 0',
    }, {
      label: 'Non Billable',
      backgroundColor: COLORS[6],
      data: aggregated_data.values.map{|v| v[:non_billable]},
      yAxisID: 'y1',
      type: 'bar',
      stack: 'Stack 0',
    }, {
      label: 'Time Off',
      backgroundColor: COLORS[9],
      data: aggregated_data.values.map{|v| v[:time_off]},
      yAxisID: 'y1',
      type: 'bar',
      stack: 'Stack 0',
    }, {
      label: 'Sellable Hours',
      backgroundColor: COLORS[2],
      data: aggregated_data.values.map{|v| v[:sellable]},
      yAxisID: 'y1',
      type: 'bar',
      stack: 'Stack 1',
    }, {
      label: 'Non Sellable Hours',
      backgroundColor: COLORS[5],
      data: aggregated_data.values.map{|v| v[:non_sellable]},
      yAxisID: 'y1',
      type: 'bar',
      stack: 'Stack 1',
    }])

    render(partial: "show", locals: {
      studio_profitability_data: studio_profitability_data,
      studio_utilization_data: studio_utilization_data,
      studio_people: studio_people,
      all_gradations: all_gradations,
      default_gradation: default_gradation
    })
  end
end
