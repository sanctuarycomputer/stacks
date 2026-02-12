ActiveAdmin.register Contributor do
  menu parent: "Team"

  config.filters = false
  config.paginate = false
  config.sort_order = "forecast_people.email_asc"
  actions :index, :show, :edit, :update
  scope :recent_new_deal_contributors, default: true
  scope :all

  controller do
    def scoped_collection
      super.joins(:forecast_person).select("contributors.*, forecast_people.email")
    end
  end

  permit_params :qbo_vendor_id, :deel_person_id

  action_item :record_misc_payment, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to(
      "Record Misc Payment",
      new_admin_contributor_misc_payment_path(resource)
    )
  end

  member_action :toggle_contributor_payout_acceptance, method: :post do
    cp = ContributorPayout.find(params[:contributor_payout_id])
    return unless cp.contributor.forecast_person.try(:admin_user) == current_admin_user || current_admin_user.is_admin?
    cp.toggle_acceptance!
    return redirect_to(
      admin_contributor_path(params[:id], format: :html),
      notice: "Success",
    )
  end

  form do |f|
    f.inputs do
      f.input :forecast_person, input_html: { disabled: true }
      f.input :qbo_vendor
      f.input :deel_person
    end
    f.actions
  end

  index download_links: false do
    column :forecast_person
    column :qbo_vendor
    column :deel_person
    column :balance do |c|
      balance = c.new_deal_balance
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
      contributor: resource,
      new_deal_ledger_items: new_deal_ledger_items,
      balance: balance
    })
  end
end
