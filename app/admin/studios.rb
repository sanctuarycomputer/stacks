ActiveAdmin.register Studio do
  config.filters = false
  config.paginate = false
  actions :index, :show, :edit, :update, :new, :create

  scope :all, default: true
  scope :client_services
  scope :internal
  scope :reinvestment

  action_item :trigger_sync_okrs, only: :show do
    link_to "Recalculate OKRs", trigger_sync_okrs_admin_studio_path(resource), method: :post
  end

  member_action :trigger_sync_okrs, method: :post do
    resource.generate_snapshot!
    redirect_to admin_studio_path(resource), notice: "OKRs synced!"
  end

  member_action :comments, method: [:get, :post, :delete] do
    if request.method == "GET"
      data = ActiveAdmin::Comment.where(resource: resource, namespace: params["namespace"]).order(created_at: :asc).map do |c|
        {
          id: c.id,
          author: {
            id: c.author.id,
            email: c.author.email,
            name: (c.author.info || {}).dig("name"),
            avatar: (c.author.info || {}).dig("image"),
            is_self: c.author.id == current_admin_user.id,
          },
          body: c.body,
          namespace: c.namespace,
          resource: {
            id: c.resource.id
          },
          time_ago_in_words: ApplicationController.helpers.time_ago_in_words(c.created_at)
        }
      end
      return render(json: { data: data })
    end

    if request.method == "POST"
      c = ActiveAdmin::Comment.create!(
        resource: resource,
        author: current_admin_user,
        body: params["body"],
        namespace: params["namespace"]
      )
      data = {
        id: c.id,
        author: {
          id: c.author.id,
          email: c.author.email,
          name: (c.author.info || {}).dig("name"),
          avatar: (c.author.info || {}).dig("image"),
          is_self: c.author.id == current_admin_user.id,
        },
        body: c.body,
        namespace: c.namespace,
        resource: {
          id: c.resource.id
        },
        time_ago_in_words: ApplicationController.helpers.time_ago_in_words(c.created_at)
      }
      return render(json: { data: data })
    end

    if request.method == "DELETE"
      c = ActiveAdmin::Comment.find(params["comment_id"]);
      raise "Unauthorized" if c.author.id != current_admin_user.id
      c.delete
      head :ok
    end
  end

  permit_params :name,
    :accounting_prefix,
    :mini_name,
    :studio_type,
    studio_coordinator_periods_attributes: [
      :id,
      :admin_user_id,
      :studio_id,
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
      f.input :studio_type,
        include_blank: false,
        as: :select

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
    column :studio_type
    column :health do |resource|
      accounting_method = session[:accounting_method] || "cash"

      if resource.client_services?
        span(class: "pill #{resource.health.dig("health")}") do
          span(class: "split") do
            strong(resource.health.dig("value"))
          end
        end
      else
        div([
          span("#{number_to_currency resource.net_revenue(accounting_method)}"),
          para(class: "okr_hint", style: "margin-bottom:0px;padding-top:0px !important") do
            "YTD Net revenue"
          end
        ])
      end
    end
    column :last_generated do |resource|
      "#{time_ago_in_words(DateTime.iso8601(resource.snapshot["finished_at"] || resource.snapshot["generated_at"]))} ago"
    end
    actions
  end

  show do
    COLORS = Stacks::Utils::COLORS

    all_gradations = ["month", "quarter", "year", "trailing_3_months", "trailing_4_months", "trailing_6_months", "trailing_12_months"]
    default_gradation = "month"
    current_gradation =
      params["gradation"] || default_gradation
    current_gradation =
      default_gradation unless all_gradations.include?(current_gradation)

    snapshot =
      resource.snapshot[current_gradation] || []
    snapshot_without_ytd = snapshot.reject{|s| s["label"] == "YTD"}
    accounting_method = session[:accounting_method] || "cash"

    datapoints_bearer = "datapoints"
    if resource.is_garden3d? && !params["include_reinvestment"].present?
      datapoints_bearer = "datapoints_excluding_reinvestment"
    end

    studio_profitability_data = {
      labels: snapshot.map{|s| s["label"]},
      datasets: [{
        label: "Profit Margin (%)",
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "profit_margin", "value")
        end),
        yAxisID: 'y1',
        fill: true,
        type: 'line'
      }, {
        label: "Payroll",
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "payroll", "value")
        end),
        backgroundColor: COLORS[1],
        stack: 'cogs'
      }, {
        label: "Benefits",
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "benefits", "value")
        end),
        backgroundColor: COLORS[2],
        stack: 'cogs'
      }, {
        label: "Profit Share, Bonuses & Misc",
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "bonuses", "value")
        end),
        backgroundColor: COLORS[2],
        stack: 'cogs'
      }, {
        label: "Total Expenses",
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "total_expenses", "value")
        end),
        backgroundColor: COLORS[3],
        stack: 'cogs'
      }, {
        label: "Subcontractors",
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "subcontractors", "value")
        end),
        backgroundColor: COLORS[4],
        stack: 'cogs'
      }, {
        label: "Supplies & Materials",
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "supplies", "value")
        end),
        backgroundColor: COLORS[5],
        stack: 'cogs'
      }, {
        label: "Revenue",
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "revenue", "value")
        end),
        backgroundColor: COLORS[0]
      }]
    }

    # YTD throws the trendline out
    studio_growth_data = {
      labels: snapshot_without_ytd.map{|s| s["label"]},
      datasets:[{
        label: "Revenue Growth (%)",
        borderColor: COLORS[2],
        data: (snapshot_without_ytd.map do |v|
          v.dig(accounting_method, datapoints_bearer, "revenue", "growth")
        end),
        type: 'line',
        trendlineLinear: {
          colorMin: COLORS[2],
          lineStyle: "dotted",
          width: 1,
        }
      }]
    }

    studio_economics_data = {
      labels: snapshot.map{|s| s["label"]},
      datasets: [{
        label: 'Average Hourly Rate Billed',
        borderColor: COLORS[0],
        type: 'line',
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "average_hourly_rate", "value")
        end)
      }, {
        label: 'Cost per Sellable Hour',
        borderColor: COLORS[1],
        type: 'line',
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "cost_per_sellable_hour", "value")
        end)
      }, {
        label: 'Actual Cost per Hour Sold',
        borderColor: COLORS[2],
        type: 'line',
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "actual_cost_per_hour_sold", "value")
        end)
      }, {
        label: 'Free Hours Given (%)',
        backgroundColor: COLORS[4],
        type: 'bar',
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "free_hours", "value")
        end),
        yAxisID: 'y1',
      }]
    }

    studio_new_biz_data = {
      labels: snapshot.map{|s| s["label"]},
      datasets: [{
        label: "Successful Proposals (%)",
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "successful_proposals", "value")
        end),
        yAxisID: 'y1',
        type: 'line',
        borderColor: COLORS[1],
        borderDash: [10,5]
      }, {
        label: 'Leads',
        backgroundColor: COLORS[0],
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "lead_count", "value")
        end),
        trendlineLinear: {
          colorMin: COLORS[2],
          lineStyle: "dotted",
          width: 3,
        }
      }]
    }

    band_tallies = resource.skill_levels_on(Date.today)

    studio_senior_ratio_data =
      band_tallies.reduce({ senior: 0, total: 0 }) do |acc, band_tally|
        name, count = band_tally

        if name.starts_with?("S") || name.starts_with?("L")
          acc[:senior] += count
        end
        acc[:total] += count
        acc
      end

    studio_talent_pool_data = {
      labels: band_tallies.keys,
      datasets: [{
        label: 'Total',
        backgroundColor: COLORS[0],
        data: band_tallies.values
      }]
    }

    studio_attrition_data = {
      labels: snapshot.map{|s| s["label"]},
      datasets: [{
        label: 'Total',
        backgroundColor: COLORS[0],
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "attrition", "value").count
        end)
      }]
    }

    [RacialBackground, CulturalBackground, GenderIdentity].each do |klass|
      studio_attrition_data[:datasets] << {
        label: "#{klass.to_s.underscore.humanize} — No Response",
        backgroundColor: COLORS[1],
        data: (snapshot.map do |v|
          v
            .dig(accounting_method, datapoints_bearer, "attrition", "value")
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
              .dig(accounting_method, datapoints_bearer, "attrition", "value")
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

    studio_dev_data = {
      labels: snapshot.map{|s| s["label"]},
      datasets: [{
        label: 'PRs Merged',
        borderColor: COLORS[0],
        type: 'line',
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "prs_merged", "value")
        end),
        yAxisID: 'y',
      }, {
        label: 'Story Points Closed',
        borderColor: COLORS[0],
        type: 'bar',
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "story_points", "value").to_f
        end),
        yAxisID: 'y',
      }, {
        label: 'Average Time to Merge PR (Days)',
        borderColor: COLORS[2],
        type: 'line',
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "time_to_merge_pr", "value").to_f
        end),
        yAxisID: 'y1',
        trendlineLinear: {
          colorMin: COLORS[2],
          lineStyle: "dotted",
          width: 1,
        }
      }]
    }

    studio_utilization_data = {
      labels: snapshot.map{|s| s["label"]},
      datasets: [{
        label: 'Utilization Rate (%)',
        borderColor: COLORS[4],
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "sellable_hours_sold", "value")
        end),
        yAxisID: 'y',
      }, {
        label: 'Sellable Ratio (%)',
        borderColor: COLORS[10],
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "sellable_hours_ratio", "value")
        end),
        yAxisID: 'y',
        borderDash: [10,5]
      }, {
        label: 'Actual Hours Sold',
        backgroundColor: COLORS[8],
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "billable_hours", "value")
        end),
        yAxisID: 'y1',
        type: 'bar',
        stack: 'Stack 0',
      }, {
        label: 'Non Billable',
        backgroundColor: COLORS[6],
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "non_billable_hours", "value")
        end),
        yAxisID: 'y1',
        type: 'bar',
        stack: 'Stack 0',
      }, {
        label: 'Time Off',
        backgroundColor: COLORS[9],
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "time_off", "value")
        end),
        yAxisID: 'y1',
        type: 'bar',
        stack: 'Stack 0',
      }, {
        label: 'Sellable Hours',
        backgroundColor: COLORS[2],
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "sellable_hours", "value")
        end),
        yAxisID: 'y1',
        type: 'bar',
        stack: 'Stack 1',
      }, {
        label: 'Non Sellable Hours',
        backgroundColor: COLORS[5],
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "non_sellable_hours", "value")
        end),
        yAxisID: 'y1',
        type: 'bar',
        stack: 'Stack 1',
      }]
    }

    all_okrs = [*Okr.all, {
      name: "Profit",
      datapoint: "profit",
      operator: "greater_than"
    }, {
      name: "Surplus Profit",
      datapoint: "surplus_profit",
      operator: "greater_than"
    }]

    if current_gradation == "month"
      all_okrs = [{
        name: "Health",
        datapoint: "health",
        operator: "greater_than"
      }, *all_okrs]
    end

    render(partial: "show", locals: {
      comments: ActiveAdmin::Comment.where(resource: resource),
      all_gradations: all_gradations,
      default_gradation: default_gradation,
      all_okrs: all_okrs,
      snapshot: snapshot,
      studio_dev_data: studio_dev_data,
      studio_profitability_data: studio_profitability_data,
      studio_growth_data: studio_growth_data,
      studio_talent_pool_data: studio_talent_pool_data,
      studio_senior_ratio_data: studio_senior_ratio_data,
      studio_economics_data: studio_economics_data,
      studio_utilization_data: studio_utilization_data,
      studio_new_biz_data: studio_new_biz_data,
      studio_attrition_data: studio_attrition_data,
    })
  end
end
