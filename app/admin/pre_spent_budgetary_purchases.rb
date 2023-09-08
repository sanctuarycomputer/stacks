ActiveAdmin.register PreSpentBudgetaryPurchase do
  menu parent: "Money"
  config.filters = false
  config.paginate = false
  actions :index, :new, :create, :edit, :update, :destroy
  config.current_filters = false
  belongs_to :budget

  permit_params :note,
    :amount,
    :budget_type,
    :spent_at

  index download_links: false do
    column :note
    column :amount do |resource|
      number_to_currency(resource.amount)
    end
    column :spent_at
    actions
  end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.input :note
      f.input :amount
      f.input :spent_at
    end

    f.actions
  end
end
