ActiveAdmin.register InvoiceTracker do
  menu label: "Invoices"
  config.filters = false
  config.paginate = false
  actions :index, :show
  belongs_to :invoice_pass

  index download_links: false, :title => proc { "Invoices for #{self.parent.invoice_month}" } do
    column :client do |resource|
      resource.forecast_client.name
    end
    actions
  end

  show do
    render 'invoice_tracker', { invoice_tracker: invoice_tracker }
  end
end
