ActiveAdmin.register Studio do
  config.filters = false
  config.paginate = false
  actions :index, :show, :edit, :update

  action_item :trigger_sync_okrs, only: :show do
    link_to "Recalculate OKRs", trigger_sync_okrs_admin_studio_path(resource), method: :post
  end

  member_action :trigger_sync_okrs, method: :post do
    resource.generate_snapshot!
    redirect_to admin_studio_path(resource), notice: "OKRs synced!"
  end

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

    snapshot =
      resource.snapshot[current_gradation] || []

    studio_profitability_data = {
      labels: snapshot.map{|s| s["label"]},
      datasets: [{
        label: "Profit Margin (%)",
        data: (snapshot.map do |v|
          v.dig("datapoints", "profit_margin", "value")
        end),
        yAxisID: 'y1',
        type: 'line'
      }, {
        label: "Payroll",
        data: (snapshot.map do |v|
          v.dig("datapoints", "payroll", "value")
        end),
        backgroundColor: COLORS[1],
        stack: 'cogs'
      }, {
        label: "Benefits",
        data: (snapshot.map do |v|
          v.dig("datapoints", "benefits", "value")
        end),
        backgroundColor: COLORS[2],
        stack: 'cogs'
      }, {
        label: "Expenses",
        data: (snapshot.map do |v|
          v.dig("datapoints", "expenses", "value")
        end),
        backgroundColor: COLORS[3],
        stack: 'cogs'
      }, {
        label: "Subcontractors",
        data: (snapshot.map do |v|
          v.dig("datapoints", "subcontractors", "value")
        end),
        backgroundColor: COLORS[4],
        stack: 'cogs'
      }, {
        label: "Supplies & Materials",
        data: (snapshot.map do |v|
          v.dig("datapoints", "supplies", "value")
        end),
        backgroundColor: COLORS[5],
        stack: 'cogs'
      }, {
        label: "Revenue",
        data: (snapshot.map do |v|
          v.dig("datapoints", "revenue", "value")
        end),
        backgroundColor: COLORS[0]
      }]
    }

    studio_economics_data = {
      labels: snapshot.map{|s| s["label"]},
      datasets: [{
        label: 'Average Hourly Rate Billed',
        borderColor: COLORS[0],
        type: 'line',
        data: (snapshot.map do |v|
          v.dig("datapoints", "average_hourly_rate", "value")
        end)
      }, {
        label: 'Cost per Sellable Hour',
        borderColor: COLORS[1],
        type: 'line',
        data: (snapshot.map do |v|
          v.dig("datapoints", "cost_per_sellable_hour", "value")
        end)
      }, {
        label: 'Actual Cost per Hour Sold',
        borderColor: COLORS[2],
        type: 'line',
        data: (snapshot.map do |v|
          v.dig("datapoints", "actual_cost_per_hour_sold", "value")
        end)
      }]
    }

    studio_new_biz_data = {
      labels: snapshot.map{|s| s["label"]},
      datasets: [{
        label: 'New',
        backgroundColor: COLORS[0],
        data: (snapshot.map do |v|
          v.dig("datapoints", "biz_leads", "value")
        end)
      }, {
        label: 'Won',
        backgroundColor: COLORS[1],
        data: (snapshot.map do |v|
          v.dig("datapoints", "biz_won", "value")
        end)
      }, {
        label: 'Lost/Stale',
        backgroundColor: COLORS[2],
        data: (snapshot.map do |v|
          v.dig("datapoints", "biz_lost", "value")
        end)
      }, {
        label: 'Passed',
        backgroundColor: COLORS[3],
        data: (snapshot.map do |v|
          v.dig("datapoints", "biz_passed", "value")
        end)
      }]
    }

    studio_attrition_data = {
      labels: snapshot.map{|s| s["label"]},
      datasets: [{
        label: 'Total',
        backgroundColor: COLORS[0],
        data: (snapshot.map do |v|
          v.dig("datapoints", "attrition", "value").count
        end)
      }]
    }

    [RacialBackground, CulturalBackground, GenderIdentity].each do |klass|
      studio_attrition_data[:datasets] << {
        label: "#{klass.to_s.underscore.humanize} — No Response",
        backgroundColor: COLORS[1],
        data: (snapshot.map do |v|
          v
            .dig("datapoints", "attrition", "value")
            .reduce(0) do |acc, m|
              acc += m["#{klass.to_s.underscore}_ids"].empty? ? 1 : 0
            end
        end),
        type: 'bar',
        stack: klass.to_s.underscore,
      }

      klass.all.each_with_index do |dei_set, index|
        studio_attrition_data[:datasets] << {
          label: "#{klass.to_s.underscore.humanize} — #{dei_set.name}",
          backgroundColor: COLORS[index + 2],
          data: (snapshot.map do |v|
            v
              .dig("datapoints", "attrition", "value")
              .reduce(0) do |acc, m|
                acc +=
                  m["#{klass.to_s.underscore}_ids"].include?(dei_set.id) ? (1.0 / m["#{klass.to_s.underscore}_ids"].count) : 0
              end
          end),
          type: 'bar',
          stack: klass.to_s.underscore,
        }
      end
    end

    studio_utilization_data = {
      labels: snapshot.map{|s| s["label"]},
      datasets: [{
        label: 'Utilization Rate (%)',
        borderColor: COLORS[4],
        data: (snapshot.map do |v|
          v.dig("datapoints", "sellable_hours_sold", "value")
        end),
        yAxisID: 'y',
      }, {
        label: 'Sellable Ratio (%)',
        borderColor: COLORS[10],
        data: (snapshot.map do |v|
          v.dig("datapoints", "sellable_hours_ratio", "value")
        end),
        yAxisID: 'y',
        borderDash: [10,5]
      }, {
        label: 'Actual Hours Sold',
        backgroundColor: COLORS[8],
        data: (snapshot.map do |v|
          v.dig("datapoints", "billable_hours", "value")
        end),
        yAxisID: 'y1',
        type: 'bar',
        stack: 'Stack 0',
      }, {
        label: 'Non Billable',
        backgroundColor: COLORS[6],
        data: (snapshot.map do |v|
          v.dig("datapoints", "non_billable_hours", "value")
        end),
        yAxisID: 'y1',
        type: 'bar',
        stack: 'Stack 0',
      }, {
        label: 'Time Off',
        backgroundColor: COLORS[9],
        data: (snapshot.map do |v|
          v.dig("datapoints", "time_off", "value")
        end),
        yAxisID: 'y1',
        type: 'bar',
        stack: 'Stack 0',
      }, {
        label: 'Sellable Hours',
        backgroundColor: COLORS[2],
        data: (snapshot.map do |v|
          v.dig("datapoints", "sellable_hours", "value")
        end),
        yAxisID: 'y1',
        type: 'bar',
        stack: 'Stack 1',
      }, {
        label: 'Non Sellable Hours',
        backgroundColor: COLORS[5],
        data: (snapshot.map do |v|
          v.dig("datapoints", "non_sellable_hours", "value")
        end),
        yAxisID: 'y1',
        type: 'bar',
        stack: 'Stack 1',
      }]
    }

    render(partial: "show", locals: {
      all_gradations: all_gradations,
      default_gradation: default_gradation,
      all_okrs: [*Okr.all.map(&:name), "Surplus Profit"].sort,
      snapshot: snapshot,
      studio_profitability_data: studio_profitability_data,
      studio_economics_data: studio_economics_data,
      studio_utilization_data: studio_utilization_data,
      studio_new_biz_data: studio_new_biz_data,
      studio_attrition_data: studio_attrition_data,
    })
  end
end
