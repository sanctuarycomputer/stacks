ActiveAdmin.register Reimbursement do
  config.filters = false
  config.paginate = false
  actions :index, :new, :show, :create, :destroy
  permit_params :contributor_id, :amount, :receipts, :description
  menu false
  
  belongs_to :contributor

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
      f.input :contributor, input_html: { disabled: true }
      f.input :amount, as: :number, input_html: { step: 0.01, min: 0.01 }, label: "Amount (in USD, eg: 120.75)"
      f.input :description, placeholder: "Travel Expenses to Taipei"
      f.input :receipts, placeholder: "Links to PDFs on Google Drive, etc"
    end

    f.actions
  end
end
  