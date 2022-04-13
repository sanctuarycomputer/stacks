ActiveAdmin.register InvoiceTracker do
  menu label: "Invoices"
  config.filters = false
  config.paginate = false
  actions :index, :show, :edit, :update
  belongs_to :invoice_pass
  permit_params :notes

  action_item :attempt_generate, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to(
      "Regenerate",
      attempt_generate_admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
      method: :post
    )
  end

  member_action :toggle_ownership, method: :post do
    if resource.admin_user.present? && resource.admin_user == current_admin_user
      resource.update!(admin_user: nil)
      return redirect_to(
        admin_invoice_pass_invoice_trackers_path(resource.invoice_pass, resource, format: :html),
        notice: "Unclaimed invoice.",
      )
    else
      resource.update!(admin_user: current_admin_user)
      return redirect_to(
        admin_invoice_pass_invoice_trackers_path(resource.invoice_pass, resource, format: :html),
        notice: "Claimed!",
      )
    end
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
    column :owner do |resource|
      if resource.admin_user.present?
        resource.admin_user
      else
      span("Unclaimed", class: "pill error")
      end
    end
    actions do |resource|
      if resource.admin_user.nil?
        link_to(
          "Claim ↗",
          toggle_ownership_admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
          method: :post
        )
      elsif resource.admin_user == current_admin_user
        link_to(
          "Unclaim ↗",
          toggle_ownership_admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
          method: :post
        )
      end
    end
  end

  controller do
    def show
      unless resource.qbo_invoice.try(:sync!)
        resource.reload
      end
      super
    end
  end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.input :notes, label: "❗Important Notes (accepts markdown)"
      #f.input :qbo_invoice
    end
    f.actions
  end

  show do
    if invoice_tracker.status == :not_made
      render 'not_made', { invoice_tracker: invoice_tracker }
    else
      render 'invoice_tracker', { invoice_tracker: invoice_tracker }
    end
  end
end
