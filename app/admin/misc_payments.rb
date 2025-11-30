ActiveAdmin.register MiscPayment do
  config.filters = false
  config.paginate = false
  actions :index, :new, :show, :create, :destroy
  permit_params :contributor_id, :amount, :paid_at, :remittance
  menu false

  belongs_to :contributor

  index download_links: false do
    column :contributor
    column :amount
    column :remittance
    column :paid_at
    actions
  end

  form do |f|
    f.inputs do
      f.semantic_errors
      f.input :contributor, input_html: { disabled: true }
      f.input :amount, as: :number, input_html: { step: 0.01, min: 0.01 }, label: "Amount (in USD, eg: 120.75)"
      f.input :paid_at, as: :date_picker
      f.input :remittance
    end

    f.actions
  end
end
