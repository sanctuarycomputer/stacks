ActiveAdmin.register Studio do
  config.filters = false
  config.paginate = false
  actions :index, :show, :edit, :update

  permit_params :name,
    :accounting_prefix,
    :mini_name,
    studio_coordinator_periods_attributes: [
      :id,
      :admin_user_id,
      :started_at,
      :ended_at,
      :_destroy,
      :_edit
    ]

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.input :name
      f.input :accounting_prefix
      f.input :mini_name

      f.has_many :studio_coordinator_periods, heading: false, allow_destroy: true, new_record: 'Add a Studio Coorindator' do |a|
        a.input :admin_user
        a.input :started_at
        a.input :ended_at
      end


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
          ends_at: time.end_of_month,
          report: QboProfitAndLossReport.find_or_fetch_for_range(
            time.beginning_of_month,
            time.end_of_month
          )
        }
        time = time.advance(months: 1)
      end
    when "quarter"
      while time < Date.today.last_quarter.end_of_quarter
        periods << {
          label: "Q#{(time.beginning_of_quarter.month / 3) + 1}, #{time.beginning_of_quarter.year}",
          starts_at: time.beginning_of_quarter,
          ends_at: time.end_of_quarter,
          report: QboProfitAndLossReport.find_or_fetch_for_range(
            time.beginning_of_quarter,
            time.end_of_quarter
          )
        }
        time = time.advance(months: 3)
      end
    when "year"
      while time < Date.today.last_year.end_of_year
        periods << {
          label: "#{time.beginning_of_quarter.year}",
          starts_at: time.beginning_of_year,
          ends_at: time.end_of_year,
          report: QboProfitAndLossReport.find_or_fetch_for_range(
            time.beginning_of_year,
            time.end_of_year,
          )
        }
        time = time.advance(years: 1)
      end
    end

    preloaded_studios = Studio.all
    studio_people = resource.utilization_by_people(periods)
    aggregated_data = resource.aggregated_utilization(studio_people)

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
      report = p[:report]
      cogs = report.cogs_for_studio(resource)

      # Revenue
      ds = studio_profitability_data[:datasets].find{|d| d[:label] == "Revenue"}
      ds[:data] << cogs[:revenue]

      # Payroll
      ds = studio_profitability_data[:datasets].find{|d| d[:label] == "Payroll"}
      ds[:data] << cogs[:payroll]

      # Benefits
      ds = studio_profitability_data[:datasets].find{|d| d[:label] == "Benefits"}
      ds[:data] << cogs[:benefits]

      # Expenses
      ds = studio_profitability_data[:datasets].find{|d| d[:label] == "Expenses"}
      ds[:data] << cogs[:expenses]

      # Subcontractors
      ds = studio_profitability_data[:datasets].find{|d| d[:label] == "Subcontractors"}
      ds[:data] << cogs[:subcontractors]

      # Margin
      ds = studio_profitability_data[:datasets].find{|d| d[:label] == "Profit Margin (%)"}
      ds[:data] << cogs[:profit_margin]
    end

    studio_economics_data = {
      labels: aggregated_data.keys,
      datasets: []
    }

    studio_economics_data[:datasets].concat([{
      label: 'Average Hourly Rate Billed',
      borderColor: COLORS[0],
      type: 'line',
      data: (aggregated_data.values.map do |v|
        Stacks::Utils.weighted_average(v[:billable].map{|k, v| [k.to_f, v]})
      end)
    }, {
      label: 'Cost per Sellable Hour',
      borderColor: COLORS[1],
      type: 'line',
      data: (aggregated_data.map do |k, v|
        cogs = v[:report].cogs_for_studio(resource)
        cogs[:cogs] / v[:sellable].to_f
      end)
    }, {
      label: 'Actual Cost per Hour Sold',
      borderColor: COLORS[2],
      type: 'line',
      data: (aggregated_data.values.map do |v|
        cogs = v[:report].cogs_for_studio(resource)
        total_billable = v[:billable].values.reduce(&:+) || 0
        cogs[:cogs] / total_billable
      end)
    }])

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
      studio_okr_data: resource.okrs,
      studio_profitability_data: studio_profitability_data,
      studio_economics_data: studio_economics_data,
      studio_utilization_data: studio_utilization_data,
      studio_people: studio_people,
      all_gradations: all_gradations,
      default_gradation: default_gradation
    })
  end
end
