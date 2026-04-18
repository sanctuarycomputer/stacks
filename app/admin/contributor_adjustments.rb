ActiveAdmin.register ContributorAdjustment do
  config.filters = false
  config.paginate = false
  actions :index, :new, :show, :edit, :create, :update, :destroy
  permit_params :contributor_id, :amount, :effective_on, :description, :qbo_invoice_id
  menu false

  belongs_to :contributor

  controller do
    # Same as InvoiceTracker#show: refresh QBO data when opening the page (paid status, balance, etc.).
    def show
      unless resource.qbo_invoice.try(:sync!)
        resource.reload
      end
      super
    end
  end

  index download_links: false do
    column :contributor
    column :amount
    column :effective_on
    column :qbo_invoice_id
    actions
  end

  form do |f|
    f.inputs do
      f.semantic_errors
      f.input :contributor, input_html: { disabled: true }
      f.input :amount, as: :number, input_html: { step: 0.01 }, label: "Amount (positive increases amount owed to contributor)"
      f.input :effective_on, as: :date_picker
      f.input :qbo_invoice,
        as: :select,
        collection: QboInvoice.order(Arel.sql("data->>'doc_number'")),
        include_blank: "None (available immediately)",
        hint: "Optional. If unset, counts toward balance immediately; if set, the adjustment stays unsettled until that invoice is fully paid in QBO."
      f.input :description, as: :text, input_html: { rows: 4 }
    end

    f.actions
  end

  show do
    render partial: "show", locals: { resource: resource }
  end
end
