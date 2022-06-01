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
    ],
    studio_key_meetings_attributes: [
      :id,
      :studio_id,
      :key_meeting_id,
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

      f.has_many :studio_key_meetings, heading: false, allow_destroy: true, new_record: 'Add a Key Meeting' do |a|
        a.input :key_meeting
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

    okrs_encountered = Set[]
    okrs_for_periods =
      periods.reduce({}) do |agg, period|
        datapoints = datapoints_for_periods[period]
        okr_periods =
          OkrPeriodStudio
            .includes(okr_period: :okr)
            .where(studio: resource)
            .select{|ops| ops.applies_to?(period)}
            .map(&:okr_period)

        agg[period] = okr_periods.reduce({}) do |acc, okrp|
          data = datapoints[okrp.okr.datapoint.to_sym]
          okrs_encountered.add(okrp.okr)
          acc[okrp.okr] = okrp.health_for_value(data[:value]).merge(data)

          # It's helpful for reinvestment to know how much
          # surplus profit we've made.
          if okrp.okr.datapoint == "profit_margin"
            faux_okr = FauxOKR.new("Surplus Profit")
            okrs_encountered.add(faux_okr)

            surplus_usd =
              datapoints[:revenue][:value] * (acc[okrp.okr][:surplus]/100)
            acc[faux_okr] = {
              health: acc[okrp.okr][:health],
              surplus: surplus_usd,
              value: surplus_usd,
              unit: :usd
            }
          end

          acc
        end
        agg
      end

    studio_okr_data = {
      labels: okrs_for_periods.keys.map(&:label),
      datasets: (okrs_encountered.each_with_index.map do |okr, i|
        {
          label: okr.name,
          backgroundColor: COLORS[i],
          data: okrs_for_periods.values.map do |okr_results|
            okr_results[okr] ? okr_results[okr][:surplus] : 0
          end
        }
      end)
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
        label: "Supplies & Materials",
        data: (datapoints_for_periods.values.map do |dp|
          dp[:supplies][:value]
        end),
        backgroundColor: COLORS[5],
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
          dp[:sellable_hours_sold][:value]
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
      okrs_encountered: okrs_encountered,
      okrs_for_periods: okrs_for_periods,
      studio_okr_data: studio_okr_data,
      studio_profitability_data: studio_profitability_data,
      studio_economics_data: studio_economics_data,
      studio_utilization_data: studio_utilization_data,
      all_gradations: all_gradations,
      default_gradation: default_gradation
    })
  end
end
