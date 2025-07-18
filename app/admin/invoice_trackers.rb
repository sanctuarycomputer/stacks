ActiveAdmin.register InvoiceTracker do
  menu label: "Invoices"
  config.filters = false
  config.paginate = false
  actions :index, :show, :edit, :update
  belongs_to :invoice_pass
  permit_params :notes, :allow_early_contributor_payouts_on, :company_treasury_split, :qbo_invoice_id

  action_item :attempt_generate, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to(
      "Regenerate",
      attempt_generate_admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
      method: :post
    )
  end

  member_action :toggle_contributor_payout_acceptance, method: :post do
    cp = ContributorPayout.find(params[:contributor_payout_id])
    return unless cp.forecast_person.try(:admin_user) == current_admin_user || current_admin_user.is_admin?
    cp.toggle_acceptance!
    return redirect_to(
      admin_invoice_pass_invoice_tracker_path(params[:invoice_pass_id], params[:id], format: :html),
      notice: "Success",
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
    column :invoicing_status do |resource|
      span(resource.status.to_s.humanize, class: "pill #{resource.status}")
    end
    column :payout_status do |resource|
      span(resource.contributor_payouts_status.to_s.humanize, class: "pill #{resource.contributor_payouts_status}")
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

    def update
      if params[:invoice_tracker][:allow_early_contributor_payouts_on].present?
        raise "Only admins can schedule early contributor payouts" unless current_admin_user.is_admin?
      end
      super
    end
  end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.input :forecast_client, input_html: { disabled: true }
      f.input :qbo_invoice,
        as: :select,
        collection: QboInvoice.orphans,
        input_html: { disabled: !current_admin_user.is_admin? }
      if current_admin_user.is_admin?
        f.input :company_treasury_split, as: :number, input_html: { step: 0.01 }
      end
      f.input :allow_early_contributor_payouts_on, as: :date_picker
      f.input :notes, label: "❗Important Notes (accepts markdown)"
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
