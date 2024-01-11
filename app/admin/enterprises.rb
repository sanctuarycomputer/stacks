ActiveAdmin.register Enterprise do
  config.filters = false
  config.paginate = false
  actions :index, :show, :new, :create, :edit, :update
  permit_params :name,     
    qbo_account_attributes: [
      :id,
      :_edit,
      :_destroy,
      :client_id,
      :client_secret,
      :realm_id,
    ]

  action_item :trigger_generate_snapshot, only: :show do
    link_to "Regenerate Data", trigger_generate_snapshot_admin_enterprise_path(resource), method: :post
  end

  member_action :trigger_generate_snapshot, method: :post do
    resource.qbo_account.sync_all!
    resource.generate_snapshot!
    redirect_to admin_enterprise_path(resource), notice: "Regenerated!"
  end

  index download_links: false do
    column :name
    column :last_generated do |resource|
      "#{time_ago_in_words(DateTime.iso8601(resource.snapshot["generated_at"]))} ago"
    end
    actions
  end

  controller do
    def update
      super do |success, failure|
        success.html {
          token_params = 
            params["enterprise"]["qbo_token"].permit!.to_h
          qbo_token = 
            resource.qbo_account&.qbo_token || QboToken.new(qbo_account: resource.qbo_account)
          
          if token_params["token"] != qbo_token.token || token_params["refresh_token"] != qbo_token.refresh_token
            qbo_token.token = token_params["token"]
            qbo_token.refresh_token = token_params["refresh_token"]
            qbo_token.save!
          end

          redirect_to(
            admin_enterprises_path,
            notice: "Cool.",
          )
        }
        failure.html {
          flash[:error] = resource.errors.full_messages.join(",")
          render "edit"
        }
      end
    end
  end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.semantic_errors
      f.input :name

      f.inputs "QBO Account", for: [:qbo_account, f.object.qbo_account || QboAccount.new] do |qbo_account|
        qbo_account.input :client_id
        qbo_account.input :client_secret
        qbo_account.input :realm_id
      end

      if f.object.qbo_account.present?
        qbo_token = f.object.qbo_account.qbo_token || QboToken.new(qbo_account: f.object.qbo_account)
        f.inputs "QBO Token", for: [:qbo_token, qbo_token] do |qbo_token_form|
          qbo_token_form.input :token, :hint => "Last refreshed #{qbo_token.updated_at ? time_ago_in_words(qbo_token.updated_at) : "never"} ago"
          qbo_token_form.input :refresh_token
        end
      end
    end

    f.actions
  end

  show do
    COLORS = Stacks::Utils::COLORS
    accounting_method = session[:accounting_method] || "cash"

    all_gradations = ["month", "quarter", "year", "trailing_3_months", "trailing_4_months", "trailing_6_months", "trailing_12_months"]
    default_gradation = "month"
    current_gradation =
      params["gradation"] || default_gradation
    current_gradation =
      default_gradation unless all_gradations.include?(current_gradation)

    qbo_accounts = resource.qbo_account.fetch_all_accounts
    cc_or_bank_accounts = qbo_accounts.select do |a|
      ["Bank", "Credit Card"].include?(a.account_type)
    end
    
    net_cash = cc_or_bank_accounts.map do |a| 
      if a.classification == "Liability"
        -1 * a.current_balance.abs 
      else
        a.current_balance
      end
    end.reduce(:+)

    burn_rates =
      [1, 2, 3].map do |month|
        report = QboProfitAndLossReport.find_or_fetch_for_range(
          (Date.today - month.months).beginning_of_month,
          (Date.today - month.months).end_of_month,
          false,
          resource.qbo_account
        )

        (
          report.find_row(accounting_method, "Total Cost of Goods Sold") +
          report.find_row(accounting_method, "Total Expenses")
        )        
      end
    average_burn_rate = burn_rates.sum(0.0) / burn_rates.length

    snapshot =
      resource.snapshot[current_gradation] || []
    snapshot_without_ytd = snapshot.reject{|s| s["label"] == "YTD"}

    profitability_data = {
      labels: snapshot.map{|s| s["label"]},
      datasets: [{
        label: "Revenue",
        data: (snapshot.map do |v|
          v.dig(accounting_method, "datapoints", "revenue", "value")
        end),
        backgroundColor: COLORS[0]
      }]
    }

    profitability_data = {
      labels: snapshot.map{|s| s["label"]},
      datasets: [{
        label: "Profit Margin (%)",
        data: (snapshot.map do |v|
          v.dig(accounting_method, "datapoints", "profit_margin", "value")
        end),
        yAxisID: 'y1',
        fill: true,
        type: 'line'
      }, {
        label: "Expenses",
        data: (snapshot.map do |v|
          v.dig(accounting_method, "datapoints", "expenses", "value")
        end),
        backgroundColor: COLORS[6],
        stack: 'cogs'
      }, {
        label: "COGS",
        data: (snapshot.map do |v|
          v.dig(accounting_method, "datapoints", "cogs", "value")
        end),
        backgroundColor: COLORS[5],
        stack: 'cogs'
      }, {
        label: "Revenue",
        data: (snapshot.map do |v|
          v.dig(accounting_method, "datapoints", "revenue", "value")
        end),
        backgroundColor: COLORS[0]
      }]
    }

    # YTD throws the trendline out
    growth_data = {
      labels: snapshot_without_ytd.map{|s| s["label"]},
      datasets:[{
        label: "Revenue Growth (%)",
        borderColor: COLORS[2],
        data: (snapshot_without_ytd.map do |v|
          v.dig(accounting_method, "datapoints", "revenue", "growth")
        end),
        type: 'line',
        trendlineLinear: {
          colorMin: COLORS[2],
          lineStyle: "dotted",
          width: 1,
        }
      }]
    }

    render(partial: "show", locals: {
      all_gradations: all_gradations,
      default_gradation: default_gradation,
      accounts: cc_or_bank_accounts,
      runway_data: {
        net_cash: net_cash,
        average_burn_rate: average_burn_rate
      },
      profitability_data: profitability_data,
      growth_data: growth_data
    })
  end
end