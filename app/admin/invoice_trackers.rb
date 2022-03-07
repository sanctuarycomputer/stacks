ActiveAdmin.register InvoiceTracker do
  menu label: "Invoices"
  config.filters = false
  config.paginate = false
  actions :index, :show
  belongs_to :invoice_pass

  action_item :attempt_generate, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to(
      "Regenerate",
      attempt_generate_admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
      method: :post
    )
  end

  member_action :attempt_generate, method: :post do
    if resource.qbo_invoice_id.present?
      return redirect_to(
        admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
        alert: "Can not attempt to generate an invoice when a QBO Invoice ID is already set. (Delete the invoice in QBO if you'd like to regenerate.)"
      )
    end

    if resource.configuration_errors.any?
      return redirect_to(
        admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
        alert: "Can not attempt to generate an invoice Configuration Errors are present."
      )
    end

    result = resource.make_invoice!
    if result.is_a?(Quickbooks::Model::Invoice)
      return redirect_to(
        admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
        notice: "Invoice regenerated."
      )
    else
      return redirect_to(
        admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
        alert: "Could not regenerate invoice."
      )
    end
  end

  controller do
    def index
      index! do |format|
        keyed_invoice_trackers =
          @invoice_trackers.reduce({}) do |acc, it|
            if it.qbo_invoice_id.present?
              acc[it.qbo_invoice_id] = it
            end
            acc
          end
        if keyed_invoice_trackers.keys.any?
          Stacks::Automator.fetch_invoices_by_ids(keyed_invoice_trackers.keys).each do |qbo_inv|
            keyed_invoice_trackers[qbo_inv.id]._qbo_invoice = qbo_inv
          end
        end
        format.html
      end
    end
  end

  index download_links: false, :title => proc { "Invoices for #{self.parent.invoice_month}" } do
    column :client do |resource|
      resource.forecast_client.name
    end
    column :value do |resource|
      number_to_currency(resource.value)
    end
    column :status do |resource|
      span(resource.status.to_s.humanize, class: "pill #{resource.status}")
    end
    actions
  end

  show do
    if invoice_tracker.status == :not_made
      render 'not_made', { invoice_tracker: invoice_tracker }
    else
      render 'invoice_tracker', { invoice_tracker: invoice_tracker }
    end
  end
end
