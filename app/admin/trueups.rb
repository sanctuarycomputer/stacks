ActiveAdmin.register Trueup do
  config.filters = false
  config.paginate = false
  actions :index, :show, :destroy
  #permit_params :invoice_pass_id, :forecast_person_id, :amount, :description
  menu false

  belongs_to :forecast_person

  index download_links: false do
    column :forecast_person
    column :amount
    column :payment_date
    actions
  end

  # form do |f|
  #   f.inputs do
  #     f.semantic_errors
  #     f.input :forecast_person, input_html: { disabled: true }
  #     f.input :amount, as: :number, input_html: { step: 0.01, min: 0.01 }, label: "Amount (in USD, eg: 120.75)"
  #     f.input :paid_at, as: :date_picker
  #     f.input :remittance
  #   end

  #   f.actions
  # end
end
