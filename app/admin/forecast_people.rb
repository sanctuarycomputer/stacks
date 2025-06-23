ActiveAdmin.register ForecastPerson do
  config.filters = false
  config.paginate = false
  menu false
  actions :index, :show

  action_item :attempt_generate, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to(
      "Record Misc Payment",
      new_admin_forecast_person_misc_payment_path(resource)
    )
  end

  index download_links: false do
    column :email
    actions
  end

  show do
    new_deal_ledger_items = resource.new_deal_ledger_items
    balance = resource.new_deal_balance(new_deal_ledger_items)

    render(partial: "show", locals: {
      forecast_person: resource,
      new_deal_ledger_items: new_deal_ledger_items,
      balance: balance
    })
  end
end
