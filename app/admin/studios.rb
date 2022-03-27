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
        periods << Stacks::Period.new(
          time.strftime("%B, %Y"),
          time.beginning_of_month,
          time.end_of_month
        )
        time = time.advance(months: 1)
      end
    when "quarter"
      while time < Date.today.last_quarter.end_of_quarter
        periods << Stacks::Period.new(
          "Q#{(time.beginning_of_quarter.month / 3) + 1}, #{time.beginning_of_quarter.year}",
          time.beginning_of_quarter,
          time.end_of_quarter
        )
        time = time.advance(months: 3)
      end
    when "year"
      while time < Date.today.last_year.end_of_year
        periods << Stacks::Period.new(
          "#{time.beginning_of_quarter.year}",
          time.beginning_of_year,
          time.end_of_year
        )
        time = time.advance(years: 1)
      end
    end

    datapoints_for_periods =
      periods.reduce({}) do |agg, period|
        agg[period] = resource.key_datapoints_for_period(period)
        agg
      end

    studio_okr_data = {
      labels: datapoints_for_periods.keys.select(&:has_utilization_data?).map(&:label),
      datasets: [{
        label: "Utilization",
        backgroundColor: COLORS[1],
        data: (datapoints_for_periods.values.map do |dp|
          next nil if dp[:utilization][:value] == :no_data
          target = 90
          diff = dp[:utilization][:value] - target
        end).compact,
        yAxisID: 'yPercentage'
      }, {
        label: "Average Hourly Rate",
        backgroundColor: COLORS[2],
        data: (datapoints_for_periods.values.map do |dp|
          next nil if dp[:average_hourly_rate][:value] == :no_data
          target = 175
          dp[:average_hourly_rate][:value] - target
        end).compact,
        yAxisID: 'yUSD'
      }, {
        label: "Cost per Sellable Hour",
        backgroundColor: COLORS[3],
        data: (datapoints_for_periods.values.map do |dp|
          next nil if dp[:cost_per_sellable_hour][:value] == :no_data
          target = 94
          target - dp[:cost_per_sellable_hour][:value]
        end).compact,
        yAxisID: 'yUSD'
      }]
    }

    studio_profitability_data = {
      labels: datapoints_for_periods.keys.map(&:label),
      datasets: [{
        label: "Profit Margin (%)",
        data: (datapoints_for_periods.values.map do |dp|
          dp[:profit_margin][:value]
        end),
        yAxisID: 'y1',
        type: 'line'
      }, {
        label: "Payroll",
        data: (datapoints_for_periods.values.map do |dp|
          dp[:payroll][:value]
        end),
        backgroundColor: COLORS[1],
        stack: 'cogs'
      }, {
        label: "Benefits",
        data: (datapoints_for_periods.values.map do |dp|
          dp[:benefits][:value]
        end),
        backgroundColor: COLORS[2],
        stack: 'cogs'
      }, {
        label: "Expenses",
        data: (datapoints_for_periods.values.map do |dp|
          dp[:expenses][:value]
        end),
        backgroundColor: COLORS[3],
        stack: 'cogs'
      }, {
        label: "Subcontractors",
        data: (datapoints_for_periods.values.map do |dp|
          dp[:subcontractors][:value]
        end),
        backgroundColor: COLORS[4],
        stack: 'cogs'
      }, {
        label: "Revenue",
        data: (datapoints_for_periods.values.map do |dp|
          dp[:revenue][:value]
        end),
        backgroundColor: COLORS[0]
      }]
    }

    studio_economics_data = {
      labels: datapoints_for_periods.keys.select(&:has_utilization_data?).map(&:label),
      datasets: [{
        label: 'Average Hourly Rate Billed',
        borderColor: COLORS[0],
        type: 'line',
        data: (datapoints_for_periods.map do |p, dp|
          next nil unless p.has_utilization_data?
          dp[:average_hourly_rate][:value]
        end).compact
      }, {
        label: 'Cost per Sellable Hour',
        borderColor: COLORS[1],
        type: 'line',
        data: (datapoints_for_periods.map do |p, dp|
          next nil unless p.has_utilization_data?
          dp[:cost_per_sellable_hour][:value]
        end).compact
      }, {
        label: 'Actual Cost per Hour Sold',
        borderColor: COLORS[2],
        type: 'line',
        data: (datapoints_for_periods.map do |p, dp|
          next nil unless p.has_utilization_data?
          dp[:actual_cost_per_hour_sold][:value]
        end).compact
      }]
    }

    studio_utilization_data = {
      labels: datapoints_for_periods.keys.select(&:has_utilization_data?).map(&:label),
      datasets: [{
        label: 'Utilization Rate (%)',
        borderColor: COLORS[4],
        data: (datapoints_for_periods.map do |p, dp|
          next nil unless p.has_utilization_data?
          dp[:utilization][:value]
        end).compact,
        yAxisID: 'y2',
      }, {
        label: 'Actual Hours Sold',
        backgroundColor: COLORS[8],
        data: (datapoints_for_periods.map do |p, dp|
          next nil unless p.has_utilization_data?
          dp[:billable_hours][:value]
        end).compact,
        yAxisID: 'y1',
        type: 'bar',
        stack: 'Stack 0',
      }, {
        label: 'Non Billable',
        backgroundColor: COLORS[6],
        data: (datapoints_for_periods.map do |p, dp|
          next nil unless p.has_utilization_data?
          dp[:non_billable_hours][:value]
        end).compact,
        yAxisID: 'y1',
        type: 'bar',
        stack: 'Stack 0',
      }, {
        label: 'Time Off',
        backgroundColor: COLORS[9],
        data: (datapoints_for_periods.map do |p, dp|
          next nil unless p.has_utilization_data?
          dp[:time_off][:value]
        end).compact,
        yAxisID: 'y1',
        type: 'bar',
        stack: 'Stack 0',
      }, {
        label: 'Sellable Hours',
        backgroundColor: COLORS[2],
        data: (datapoints_for_periods.map do |p, dp|
          next nil unless p.has_utilization_data?
          dp[:sellable_hours][:value]
        end).compact,
        yAxisID: 'y1',
        type: 'bar',
        stack: 'Stack 1',
      }, {
        label: 'Non Sellable Hours',
        backgroundColor: COLORS[5],
        data: (datapoints_for_periods.map do |p, dp|
          next nil unless p.has_utilization_data?
          dp[:non_sellable_hours][:value]
        end).compact,
        yAxisID: 'y1',
        type: 'bar',
        stack: 'Stack 1',
      }]
    }

    render(partial: "show", locals: {
      studio_okr_data: studio_okr_data,
      studio_profitability_data: studio_profitability_data,
      studio_economics_data: studio_economics_data,
      studio_utilization_data: studio_utilization_data,
      all_gradations: all_gradations,
      default_gradation: default_gradation
    })
  end
end
