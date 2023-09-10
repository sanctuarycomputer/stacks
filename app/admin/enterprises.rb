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

      qbo_token = f.object.qbo_account.qbo_token || QboToken.new(qbo_account: f.object.qbo_account)
      f.inputs "QBO Token", for: [:qbo_token, qbo_token] do |qbo_token_form|
        qbo_token_form.input :token, :hint => "Last refreshed #{time_ago_in_words(qbo_token.updated_at)} ago"
        qbo_token_form.input :refresh_token
      end
    end

    f.actions
  end
end