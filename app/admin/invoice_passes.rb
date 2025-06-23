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

  index download_links: false, title: "Monthly Invoicing" do
    column :start_of_month
    column :value do |resource|
      number_to_currency(resource.value)
    end
    column :outstanding_balance do |resource|
      number_to_currency(resource.balance)
    end

    column :invoicing_statuses do |resource|
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

    column :payout_statuses do |resource|
      div do
        if resource.payout_statuses == :missing_hours
          span("Missing hours", class: "pill missing_hours")
        else
          resource.payout_statuses.each do |status, count|
            span("#{count}x #{status.to_s.humanize}", class: "pill #{status}")
          end
        end
      end
    end

    actions do |resource|
      link_to "Invoice Trackers →", admin_invoice_pass_invoice_trackers_path(resource)
    end
  end

  show title: :invoice_month do
    hours_report =
      ForecastPerson.all.reject(&:archived).map do |fp|
        next nil if fp.roles.include?("Subcontractor")

        missing_hours = fp.missing_allocation_during_range_in_hours(
          resource.start_of_month.beginning_of_month,
          resource.start_of_month.end_of_month,
        )
        next nil unless missing_hours > 0
        {
          forecast_person: fp,
          missing_allocation: missing_hours,
        }
      end.compact

    render 'invoice_pass', { invoice_pass: invoice_pass, hours_report: hours_report }
  end
end
