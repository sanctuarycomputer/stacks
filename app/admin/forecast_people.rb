ActiveAdmin.register ForecastPerson do
  config.filters = false
  config.paginate = false
  menu false
  actions :index, :show

  scope :active, default: true
  scope :archived

  action_item :record_misc_payment, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to(
      "Record Misc Payment",
      new_admin_forecast_person_misc_payment_path(resource)
    )
  end

  member_action :toggle_contributor_payout_acceptance, method: :post do
    cp = ContributorPayout.find(params[:contributor_payout_id])
    return unless cp.forecast_person.try(:admin_user) == current_admin_user || current_admin_user.is_admin?
    cp.toggle_acceptance!
    return redirect_to(
      admin_forecast_person_path(params[:id], format: :html),
      notice: "Success",
    )
  end

  index download_links: false do
    column :email
    column :balance do |fp|
      balance = fp.new_deal_balance
      if balance[:unsettled] > 0
        "#{number_to_currency(balance[:balance])} (#{number_to_currency(balance[:unsettled])} unsettled)"
      else
        number_to_currency(balance[:balance])
      end
    end
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
