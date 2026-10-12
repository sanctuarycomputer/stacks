ActiveAdmin.register InvoicePass do
  menu label: "Invoicing", parent: "Money"
  config.filters = false
  config.sort_order = 'start_of_month_desc'
  config.paginate = true
  config.per_page = 12
  actions :index, :show

  controller do
    def scoped_collection
      # surplus_chunks → calculate_surplus walks every contributor_payout's
      # ledger → contributor → forecast_person chain. Without these eager
      # loads each row's surplus column re-fired N queries per tracker per
      # payout. Production showed /admin/invoice_passes index at 4s for
      # 12 rows.
      super.includes(
        :enterprise,
        invoice_trackers: [
          :qbo_invoice,
          { contributor_payouts: { ledger: { contributor: :forecast_person } } },
        ],
      )
    end

    # calculate_surplus calls invoice_tracker.project_trackers per payout,
    # which fires 2 queries per tracker without batching. Page had ~120
    # trackers → 240 queries. Batch-resolve everything in two queries
    # total before the view renders by hooking find_collection.
    def find_collection(*args)
      collection = super
      if action_name == "index"
        InvoiceTracker.batch_preload_project_trackers!(
          collection.to_a.flat_map(&:invoice_trackers),
        )
      end
      collection
    end
  end

  action_item :rerun_invoice_pass, only: :show,
    if: proc { resource.enterprise == Enterprise.sanctuary } do
    link_to 'Send Reminders',
      rerun_invoice_pass_admin_invoice_pass_path(resource), method: :post
  end

  action_item :rerun_invoice_pass_without_reminders, only: :show,
    if: proc { resource.enterprise == Enterprise.sanctuary } do
    link_to 'Generate Invoices',
      rerun_invoice_pass_without_reminders_admin_invoice_pass_path(resource), method: :post
  end

  member_action :rerun_invoice_pass_without_reminders, method: :post do
    unless resource.enterprise == Enterprise.sanctuary
      return redirect_to admin_invoice_pass_path(resource),
        alert: "Forecast invoicing only runs on #{Enterprise::SANCTUARY_NAME}'s passes."
    end
    Stacks::Automator.attempt_invoicing_for_invoice_pass(resource, false)
    redirect_to admin_invoice_pass_path(resource), notice: "Done!"
  end

  member_action :rerun_invoice_pass, method: :post do
    unless resource.enterprise == Enterprise.sanctuary
      return redirect_to admin_invoice_pass_path(resource),
        alert: "Forecast invoicing only runs on #{Enterprise::SANCTUARY_NAME}'s passes."
    end
    Stacks::Automator.attempt_invoicing_for_invoice_pass(resource)
    redirect_to admin_invoice_pass_path(resource), notice: "Done!"
  end

  # --- garden3d's management fee -------------------------------------------
  # The ONLY places a management fee invoice is written to QuickBooks are
  # this action and "Regenerate" on a single tracker. Both are an admin's
  # click; nothing scheduled does it. AdminAuthorization enforces admin-only
  # on the server -- the `if:` below only hides the button.

  # Opening a month gives it garden3d's pass and a tracker per paying company
  # (Mso::ManagementFeeInvoices.ensure_month!). DATABASE ONLY: it never calls
  # QuickBooks. The nightly run already opens every month from the start
  # month on, so this is for an earlier month whose hand-made invoices are to
  # be attached, and for the current month before the nightly run reaches it.
  action_item :open_management_fee_month, only: :index, if: proc { current_admin_user.is_admin? } do
    months = Mso::ManagementFeeInvoices.openable_months
    render(partial: "admin/invoice_passes/open_management_fee_month", locals: { months: months }) if months.any?
  end

  collection_action :open_management_fee_month, method: :post do
    # A collection action loads no record, so ActiveAdmin authorizes nothing
    # on its own. Admin-only, in AdminAuthorization.
    authorize! :open_management_fee_month, InvoicePass

    month =
      begin
        Date.strptime(params[:month].to_s, "%Y-%m")
      rescue ArgumentError
        nil
      end
    if month.nil? || month > Date.today.beginning_of_month
      return redirect_to admin_invoice_passes_path, alert: "Choose a month, no later than the current one."
    end

    begin
      # Raises LegacyPass for a month whose pass holds a legacy Forecast
      # tracker, and Misconfigured when a payer is not set up.
      pass = Mso::ManagementFeeInvoices.ensure_month!(month)
    rescue Mso::ManagementFeeInvoices::Error => e
      return redirect_to admin_invoice_passes_path, alert: e.message
    end

    redirect_to admin_invoice_pass_path(pass),
      notice: "#{Enterprise::GARDEN3D_NAME}'s pass for #{pass.invoice_month} is open, with a tracker for each " \
              "paying company. Nothing was sent to QuickBooks."
  end

  action_item :create_management_fee_drafts, only: :show,
    if: proc { current_admin_user.is_admin? && Mso::ManagementFeeInvoices.draftable?(resource) } do
    link_to "Create management fee drafts",
      create_management_fee_drafts_admin_invoice_pass_path(resource),
      method: :post,
      data: { confirm: "Create a $0.00 draft invoice in garden3d's QuickBooks for each paying company that " \
                       "does not have one for #{resource.invoice_month}? Stacks first checks QuickBooks and " \
                       "skips any company that already has an invoice dated in this month." }
  end

  action_item :refresh_management_fee_invoices, only: :show,
    if: proc {
      current_admin_user.is_admin? && resource.management_fee? && !resource.legacy_forecast_trackers?
    } do
    link_to "Refresh from QuickBooks",
      refresh_management_fee_invoices_admin_invoice_pass_path(resource), method: :post
  end

  member_action :create_management_fee_drafts, method: :post do
    unless current_admin_user.is_admin?
      return redirect_to admin_invoice_pass_path(resource), alert: "Management fee drafts are created by an admin."
    end

    begin
      # Raises WrongPass off garden3d's pass, and NotDraftable before
      # MANAGEMENT_FEE_START or on a pass holding a legacy Forecast tracker.
      # A payer QuickBooks already holds an invoice for is reported in
      # run.failed, with that invoice mirrored for attaching.
      run = Mso::ManagementFeeInvoices.create_drafts!(invoice_pass: resource)
    rescue Mso::ManagementFeeInvoices::Error => e
      return redirect_to admin_invoice_pass_path(resource), alert: e.message
    end

    summary = "Created #{run.created.size} draft(s) in QuickBooks; " \
              "#{run.already_drafted.size} already had an invoice."
    if run.failed.any?
      failures = run.failed.map { |tracker, message| "#{tracker.forecast_client.name}: #{message}" }.join(" | ")
      redirect_to admin_invoice_pass_path(resource), alert: "#{summary} Failed: #{failures}"
    else
      redirect_to admin_invoice_pass_path(resource), notice: summary
    end
  end

  member_action :refresh_management_fee_invoices, method: :post do
    unless current_admin_user.is_admin?
      return redirect_to admin_invoice_pass_path(resource), alert: "Management fee invoices are refreshed by an admin."
    end

    begin
      run = Mso::ManagementFeeInvoices.refresh!(invoice_pass: resource)
    rescue Mso::ManagementFeeInvoices::Error => e
      return redirect_to admin_invoice_pass_path(resource), alert: e.message
    end

    # What Stacks holds for these invoices has just changed. Whether the fee
    # is collected has to be confirmed again (Check collection, or a run).
    MsoSnapshot.unconfirm_collection!(resource.id)

    summary = "Refreshed #{run.succeeded} of #{run.attempted} invoice(s) from QuickBooks."
    if run.detached.positive?
      summary += " #{run.detached} no longer exist(s) in QuickBooks and was detached."
    end
    if run.failed.any?
      # Never a green notice when some of what is on screen is stale.
      redirect_to admin_invoice_pass_path(resource),
        alert: "#{summary} Could not read the invoice on InvoiceTracker #{run.failed.map(&:id).join(', ')}; " \
               "what Stacks shows for it may be out of date. Try again."
    else
      redirect_to admin_invoice_pass_path(resource), notice: summary
    end
  end

  index download_links: false, title: "Monthly Invoicing" do
    column :start_of_month
    column :enterprise

    # Aggregate financials/statuses expose company-wide revenue data.
    # Project-scoped grantees only get :read on InvoicePass so they can
    # navigate to their own invoice trackers — they don't get to see
    # everyone else's numbers, so gate these columns to admins/leads.
    if current_admin_user.is_admin? || current_admin_user.can_act_as_lead?
      column :value do |resource|
        number_to_currency(resource.value)
      end
      column :outstanding do |resource|
        number_to_currency(resource.balance)
      end
      column :surplus do |resource|
        number_to_currency(resource.surplus)
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
    end

    actions do |resource|
      link_to "Invoice Trackers →", admin_invoice_pass_invoice_trackers_path(resource)
    end
  end

  show title: :invoice_month do
    if resource.management_fee? && !resource.legacy_forecast_trackers?
      # No Forecast hours, no generator errors: this pass holds garden3d's
      # management fee invoices and nothing else that page describes.
      render 'management_fee_pass', {
        invoice_pass: invoice_pass,
        draftable: Mso::ManagementFeeInvoices.draftable?(invoice_pass),
      }
    else
      # Sanctuary's passes, and garden3d's seven 2025 passes that each hold a
      # legacy Forecast tracker: rendered exactly as before.
      #
      # Same company-wide exposure concern as the index aggregates: the
      # missing-hours report lists every contributor's name + missing
      # allocation, not just those tied to the viewer's scoped projects.
      # Scoped grantees get an empty report — the partial no-ops on empty.
      hours_report = if current_admin_user.is_admin? || current_admin_user.can_act_as_lead?
        Stacks::Automator.discover_people_missing_hours_for_month(
          [],
          resource.start_of_month,
        ).map do |d|
          {
            forecast_person: d[:forecast_data],
            missing_allocation: d[:missing_allocation]
          }
        end
      else
        []
      end

      render 'invoice_pass', { invoice_pass: invoice_pass, hours_report: hours_report }
    end
  end
end
