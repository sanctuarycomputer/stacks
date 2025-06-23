ActiveAdmin.register ContributorPayout do
  config.filters = false
  config.paginate = false
  actions :index, :new, :create, :destroy
  permit_params :forecast_person_id, :amount, :description, :created_by_id, :blueprint
  menu false

  belongs_to :invoice_tracker

  action_item :make_payouts, only: :index do
    link_to "Calculate Default Payouts", make_payouts_admin_invoice_tracker_contributor_payouts_path(invoice_tracker),
      method: :post,
      data: { confirm: "Are you sure you want to re-calculate the payouts for this invoice? This will delete/overwrite any custom payouts previously configured." }
  end

  member_action :toggle_acceptance, method: :post do
    cp = ContributorPayout.find(params[:id])
    return unless cp.forecast_person.try(:admin_user) == current_admin_user
    cp.toggle_acceptance!
    return redirect_to(
      admin_invoice_tracker_contributor_payouts_path(cp.invoice_tracker, cp, format: :html),
      notice: "Success",
    )
  end

  collection_action :make_payouts, method: :post do
    invoice_tracker = InvoiceTracker.find(params["invoice_tracker_id"])
    invoice_tracker.make_contributor_payouts!(current_admin_user)
    redirect_to admin_invoice_tracker_contributor_payouts_path(invoice_tracker), notice: "Payouts processed!"
  end

  controller do
    def scoped_collection
      super.with_deleted.includes(:forecast_person)
    end

    def create
      params[:contributor_payout]["created_by_id"] = current_admin_user.id
      params[:contributor_payout]["blueprint"] = {}
      super
    end
  end

  index download_links: false do
    column :status do |cp|
      span(cp.status.to_s.humanize, class: "pill #{cp.status}")
    end
    column :payee do |cp|
      cp.forecast_person
    end
    column :as_account_lead do |cp|
      number_to_currency(cp.as_account_lead)
    end
    column :as_team_lead do |cp|
      number_to_currency(cp.as_team_lead)
    end
    column :as_ic do |cp|
      number_to_currency(cp.as_individual_contributor)
    end
    column :amount do |cp|
      number_to_currency(cp.amount)
    end
    column :created_by
    column :accepted?

    actions do |resource|
      if resource.forecast_person.try(:admin_user) == current_admin_user
        if resource.accepted?
          link_to(
            "Unaccept",
            toggle_acceptance_admin_invoice_tracker_contributor_payout_path(resource.id, resource),
            method: :post
          )
        else
          link_to(
            "Accept",
            toggle_acceptance_admin_invoice_tracker_contributor_payout_path(resource.id, resource),
            method: :post
          )
        end
      end
    end
  end

  form do |f|
    f.inputs do
      f.semantic_errors
      f.input :invoice_tracker, input_html: { disabled: true }
      f.input :forecast_person
      f.input :amount
      f.input :description
    end

    f.actions
  end
end
