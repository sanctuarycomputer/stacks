ActiveAdmin.register ExpenseGroup do
  config.filters = false
  config.paginate = false
  actions :index, :new, :create, :edit, :update, :destroy
  permit_params :name, :matcher
  menu false

  action_item :see_unmatched_expenses, only: :index do
    link_to 'All Expenses', admin_qbo_purchase_line_items_path
  end

  index download_links: false do
    column :name
    column :matcher
    column :spent_last_month do |resource|
      number_to_currency(resource.spent_last_month)
    end
    column :spent_last_year do |resource|
      number_to_currency(resource.spent_last_year)
    end
    column :spent_all_time do |resource|
      number_to_currency(resource.spent_all_time)
    end
    actions do |resource|
      link_to "Matched↗", admin_qbo_purchase_line_items_path(
        order: "txn_date_desc",
        "q[expense_group_id_eq]": resource.id,
        scope: "matched"
      )
    end
  end
end
