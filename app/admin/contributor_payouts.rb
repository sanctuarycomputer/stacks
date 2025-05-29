ActiveAdmin.register ContributorPayout do
  config.filters = false
  config.paginate = false
  actions :index, :new, :create, :edit, :update, :destroy
  permit_params :contributor_id, :contributor_type, :amount
  menu false

  belongs_to :invoice_tracker

  action_item :make_payouts, only: :index do
    link_to "Calculate Default Payouts", make_payouts_admin_invoice_tracker_contributor_payouts_path(invoice_tracker),
      method: :post,
      data: { confirm: "Are you sure you want to re-calculate the payouts for this invoice? This will delete/overwrite any custom payouts previously configured." }
  end

  collection_action :make_payouts, method: :post do
    invoice_tracker = InvoiceTracker.find(params["invoice_tracker_id"])
    invoice_tracker.make_contributor_payouts!
    redirect_to admin_invoice_tracker_contributor_payouts_path(invoice_tracker), notice: "Payouts processed!"
  end

  index download_links: false do
    column :contributor
    column :as_account_lead do |cp|
      number_to_currency(cp.as_account_lead)
    end
    column :as_team_lead do |cp|
      number_to_currency(cp.as_team_lead)
    end
    column :as_individual_contributor do |cp|
      number_to_currency(cp.as_individual_contributor)
    end
    column :amount do |cp|
      number_to_currency(cp.amount)
    end
    actions
  end

  form do |f|
    f.inputs do
      f.semantic_errors
      f.input :contributor, as: :select, collection: (
        AdminUser.all +
        ForecastPerson.includes(:admin_user).select{|fp| fp.admin_user.nil? && fp.email.present?}
      ), prompt: "Select Contributor"
      f.input :amount
    end

    f.actions
  end
end
