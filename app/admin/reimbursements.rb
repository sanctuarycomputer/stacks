ActiveAdmin.register Reimbursement do
  config.filters = false
  config.paginate = false
  actions :index, :new, :show, :create, :destroy
  permit_params :amount, :receipts, :description, :ledger_id
  menu false

  belongs_to :ledger

  action_item :toggle_acceptance, only: :show do
    if current_admin_user.is_admin?
      link_to resource.accepted? ? "Deny" : "Accept", toggle_reimbursement_acceptance_admin_contributor_path(resource.contributor, {reimbursement_id: resource.id}),
        method: :post
    end
  end

  action_item :sync_qbo_bill, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to "Sync QBO Bill", sync_qbo_bill_admin_ledger_reimbursement_path(resource.ledger, resource),
      method: :post
  end

  member_action :sync_qbo_bill, method: :post do
    resource.sync_qbo_bill!
    redirect_to admin_ledger_reimbursement_path(resource.ledger, resource), notice: "Success"
  rescue => e
    Rails.logger.error("[reimbursement_sync_qbo_bill] reimbursement=#{resource.id}: #{e.class}: #{e.message}")
    redirect_to admin_ledger_reimbursement_path(resource.ledger, resource), alert: "Sync failed: #{e.message}"
  end

  index download_links: false do
    column :description
    column :contributor
    column :amount
    actions do |resource|
      if current_admin_user.is_admin?
        if resource.accepted?
          link_to(
            "Deny",
            toggle_reimbursement_acceptance_admin_contributor_path(resource.contributor, {reimbursement_id: resource.id}),
            method: :post
          )
        else
          link_to(
            "Accept",
            toggle_reimbursement_acceptance_admin_contributor_path(resource.contributor, {reimbursement_id: resource.id}),
            method: :post
          )
        end
      end
    end
  end

  form do |f|
    f.inputs do
      f.semantic_errors
      ledger_collection = Ledger.includes(:enterprise, contributor: :forecast_person).map do |l|
        ["#{l.enterprise.name} — #{l.contributor.forecast_person&.email}", l.id]
      end
      # Canonical URL is ledger-nested, so the ledger is always known from
      # the URL — render it as a disabled select for context and pin the id
      # via a hidden field.
      f.input :ledger,
        as: :select,
        collection: ledger_collection,
        selected: f.object.ledger_id,
        input_html: { disabled: true }
      f.input :ledger_id, as: :hidden
      f.input :amount, as: :number, input_html: { step: 0.01, min: 0.01 }, label: "Amount (in USD, eg: 120.75)"
      f.input :description, placeholder: "Travel Expenses to Taipei"
      f.input :receipts, placeholder: "Links to PDFs on Google Drive, etc"
    end

    f.actions
  end

  show do
    render(partial: "show", locals: { resource: resource })
  end
end
