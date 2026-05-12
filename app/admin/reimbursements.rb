ActiveAdmin.register Reimbursement do
  config.filters = false
  config.paginate = false
  actions :index, :new, :show, :create, :destroy
  permit_params :amount, :receipts, :description, :ledger_id
  menu false

  belongs_to :ledger, optional: true

  action_item :toggle_acceptance, only: :show do
    if current_admin_user.is_admin?
      link_to resource.accepted? ? "Deny" : "Accept", toggle_reimbursement_acceptance_admin_contributor_path(resource.contributor, {reimbursement_id: resource.id}),
        method: :post
    end
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
      if parent && parent.is_a?(Ledger)
        # Nested under a ledger: show the ledger as a DISABLED select with the
        # human-friendly label, so admin sees full context but can't change it.
        f.input :ledger,
          as: :select,
          collection: ledger_collection,
          selected: f.object.ledger_id,
          input_html: { disabled: true }
        # Submit ledger_id via a hidden field so the disabled select doesn't drop it.
        f.input :ledger_id, as: :hidden
      else
        f.input :ledger,
          as: :select,
          collection: ledger_collection,
          selected: f.object.ledger_id
      end
      f.input :amount, as: :number, input_html: { step: 0.01, min: 0.01 }, label: "Amount (in USD, eg: 120.75)"
      f.input :description, placeholder: "Travel Expenses to Taipei"
      f.input :receipts, placeholder: "Links to PDFs on Google Drive, etc"
    end

    f.actions
  end
end
