ActiveAdmin.register Budget do
  menu parent: "Money"
  config.filters = false
  config.paginate = false
  actions :index, :update, :edit
  config.current_filters = false

  permit_params :notes, :amount

  index download_links: false do
    column :name
    column :amount do |resource|
      number_to_currency(resource.amount)
    end
    column :spent do |resource|
      if resource.spent > resource.amount
        span("#{number_to_currency(resource.spent)}", class: "pill not_sent")
      else
        span("#{number_to_currency(resource.spent)}", class: "pill paid")
      end
    end
    column :budget_type
    column :purchases do |resource|
      link_to "View Purchases", admin_budget_pre_spent_budgetary_purchases_path(resource)
    end
    actions
  end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.input :name, input_html: { disabled: true } 
      f.input :budget_type, input_html: { disabled: true } 
      f.input :notes
      f.input :amount
    end

    f.actions
  end
end
