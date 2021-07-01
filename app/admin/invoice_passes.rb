ActiveAdmin.register InvoicePass do
  config.filters = false
  config.sort_order = 'start_of_month_desc'
  config.paginate = false
  actions :index, :show

  action_item :rerun_invoice_pass, only: :show do
    link_to 'Rerun Invoice Pass', rerun_invoice_pass_admin_invoice_pass_path(resource), method: :post
  end

  member_action :rerun_invoice_pass, method: :post do
    Stacks::Automator.attempt_invoicing_for_invoice_pass(resource)
    redirect_to admin_invoice_pass_path(resource), notice: "Done!"
  end

  index download_links: false do
    column :start_of_month
    actions
  end

  show title: :invoice_month do
    qbo_invoices = Stacks::Automator.fetch_all_invoices
    render 'invoice_pass', { invoice_pass: invoice_pass, qbo_invoices: qbo_invoices }
  end
end
