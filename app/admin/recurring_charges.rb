ActiveAdmin.register RecurringCharge do
    config.filters = false
    config.paginate = false
    actions :index, :new, :show, :create, :edit, :update, :destroy
    permit_params :forecast_client_id, :description, :unit_price, :quantity, :qbo_account_name
    menu label: "Recurring Charges", parent: "Money"

    index download_links: false do
      column :forecast_client
      column :description
      column :unit_price
      column :quantity
      column :qbo_account_name
      actions
    end
  
    form do |f|
      f.inputs(class: "admin_inputs") do    
        f.input :forecast_client
        f.input :description
        f.input :unit_price
        f.input :quantity
        f.input :qbo_account_name
      end
  
      f.actions
    end
  end
  