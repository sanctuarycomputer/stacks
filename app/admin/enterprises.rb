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

  index download_links: false do
    column :name
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
      profitability_data: profitability_data,
      growth_data: growth_data
    })
  end
end