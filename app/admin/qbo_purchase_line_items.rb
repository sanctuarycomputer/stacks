ActiveAdmin.register QboPurchaseLineItem do
  #filter :expense_group
  config.sort_order = "txn_date_desc"
  config.current_filters = false
  config.filters = false
  config.paginate = true
  actions :index
  scope :unmatched, default: true
  scope :matched
  scope :errored
  permit_params :name, :matcher
  menu false

  index download_links: false do
    column :txn_date
    column :description
    column :amount
    if params["scope"] == "matched"
      column :expense_group
    end
    if params["scope"] == "errored"
      column :conflicting_expense_groups do |resource|
        ExpenseGroup.find(resource.data.dig("errors", "conflicting_expense_groups"))
      end
    end
    actions
  end
end
