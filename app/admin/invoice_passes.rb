ActiveAdmin.register InvoicePass do
  menu label: "Invoicing", parent: "Money"
  config.filters = false
  config.sort_order = 'start_of_month_desc'
  config.paginate = false
  actions :index, :show

  action_item :rerun_invoice_pass, only: :show do
    link_to 'Send Reminders',
      rerun_invoice_pass_admin_invoice_pass_path(resource), method: :post
  end

  action_item :rerun_invoice_pass_without_reminders, only: :show do
    link_to 'Generate Invoices',
      rerun_invoice_pass_without_reminders_admin_invoice_pass_path(resource), method: :post
  end

  member_action :rerun_invoice_pass_without_reminders, method: :post do
    Stacks::Automator.attempt_invoicing_for_invoice_pass(resource, false)
    redirect_to admin_invoice_pass_path(resource), notice: "Done!"
  end

  member_action :rerun_invoice_pass, method: :post do
    Stacks::Automator.attempt_invoicing_for_invoice_pass(resource)
    redirect_to admin_invoice_pass_path(resource), notice: "Done!"
  end

  controller do
    def index
      index! do |format|
        qbo_invoice_ids =
          @invoice_passes.map{|ip| ip.invoice_trackers.map(&:qbo_invoice_id)}.flatten.compact
        qbo_invoices =
          Stacks::Automator.fetch_invoices_by_ids(qbo_invoice_ids).reduce({}) do |acc, qbo_inv|
            acc[qbo_inv.id] = qbo_inv
            acc
          end

        @invoice_passes.each do |ip|
          ip.invoice_trackers.each do |it|
            it._qbo_invoice = qbo_invoices[it.qbo_invoice_id]
          end
        end

        format.html
      end
    end
  end

  index download_links: false, title: "Monthly Invoicing" do
    column :start_of_month
    column :value do |resource|
      number_to_currency(resource.value)
    end
    column :statuses do |resource|
      div do
        if resource.statuses == :missing_hours
          span("Missing hours", class: "pill missing_hours")
        else
          resource.statuses.each do |status, count|
            span("#{count}x #{status.to_s.humanize}", class: "pill #{status}")
          end
        end
      end
    end

    column :invoices do |resource|
      link_to "View Invoices", admin_invoice_pass_invoice_trackers_path(resource)
    end
    actions
  end

  show title: :invoice_month do
    qbo_invoices = Stacks::Automator.fetch_invoices_by_ids(invoice_pass.latest_invoice_ids)
    render 'invoice_pass', { invoice_pass: invoice_pass, qbo_invoices: qbo_invoices }
  end
end
