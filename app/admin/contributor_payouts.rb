ActiveAdmin.register ContributorPayout do
  config.filters = false
  config.paginate = false
  actions :index, :new, :show, :edit, :update, :create, :destroy
  permit_params :contributor_id, :amount, :description, :created_by_id, :blueprint
  menu false

  belongs_to :invoice_tracker

  action_item :make_payouts, only: :index, if: proc { current_admin_user.is_admin? } do
    link_to "Calculate Default Payouts", make_payouts_admin_invoice_tracker_contributor_payouts_path(invoice_tracker),
      method: :post,
      data: { confirm: "Are you sure you want to re-calculate the payouts for this invoice? This will delete/overwrite any custom payouts previously configured." }
  end

  action_item :toggle_acceptance, only: :show do
    if current_admin_user == resource.contributor.forecast_person.admin_user || current_admin_user.is_admin?
      link_to resource.accepted? ? "Unaccept" : "Accept", toggle_contributor_payout_acceptance_admin_invoice_pass_invoice_tracker_path(resource.invoice_tracker.invoice_pass.id, resource.invoice_tracker, {contributor_payout_id: resource.id}),
        method: :post
    end
  end

  action_item :sync_qbo_bill, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to "Sync QBO Bill", sync_qbo_bill_admin_invoice_tracker_contributor_payout_path(resource.invoice_tracker, resource),
      method: :post
  end

  member_action :sync_qbo_bill, method: :post do
    cp = ContributorPayout.find(params[:id])
    cp.sync_qbo_bill!
    return redirect_to(
      admin_invoice_tracker_contributor_payout_path(cp.invoice_tracker, cp),
      notice: "Success",
    )
  end

  member_action :toggle_acceptance, method: :post do
    cp = ContributorPayout.find(params[:id])
    return unless cp.contributor.forecast_person.try(:admin_user) == current_admin_user || current_admin_user.is_admin?
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
    column :contributor
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
      if resource.contributor.forecast_person.try(:admin_user) == current_admin_user || current_admin_user.is_admin?
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
      f.input :contributor
      f.input :amount
      f.input :description
    end

    f.actions
  end

  show do
    render(partial: 'show', locals: {
      resource: resource
    })
  end
end
