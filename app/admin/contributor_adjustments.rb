ActiveAdmin.register ContributorAdjustment do
  config.filters = false
  config.paginate = false
  actions :index, :new, :show, :edit, :create, :update, :destroy
  permit_params :amount, :effective_on, :description, :qbo_invoice_id, :ledger_id
  menu false

  belongs_to :ledger, optional: true

  action_item :sync_qbo_bill, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to "Sync QBO Bill",
      sync_qbo_bill_admin_ledger_contributor_adjustment_path(resource.ledger, resource),
      method: :post
  end

  member_action :sync_qbo_bill, method: :post do
    adj = ContributorAdjustment.find(params[:id])
    adj.sync_qbo_bill!
    redirect_to(
      admin_ledger_contributor_adjustment_path(adj.ledger, adj),
      notice: "Success"
    )
  end

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
