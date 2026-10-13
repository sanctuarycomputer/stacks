ActiveAdmin.register InvoicePass do
  menu label: "Invoicing", parent: "Money"
  config.filters = false
  config.sort_order = 'start_of_month_desc'
  config.paginate = true
  config.per_page = 12
  actions :index, :show

  # One list per enterprise that issues invoices. garden3d's passes are
  # admin-only (AdminAuthorization), so its tab is too.
  scope("Sanctuary", default: true) do |passes|
    passes.where(enterprise_id: Enterprise.where(name: Enterprise::SANCTUARY_NAME).select(:id))
  end
  scope("garden3d", if: proc { current_admin_user.is_admin? }) do |passes|
    passes.where(enterprise_id: Enterprise.where(name: Enterprise::GARDEN3D_NAME).select(:id))
  end

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

    private

    # garden3d's month: a tracker for each enterprise it bills, then a $0.00
    # draft in garden3d's QuickBooks for each tracker that has no invoice.
    # WRITES TO QUICKBOOKS, and only ever from this click. One enterprise
    # failing is reported and does not stop the others. An enterprise Finance
    # already invoiced by hand is one such failure: Stacks finds that invoice,
    # makes no second, and lists it on the tracker's edit page to attach.
    def make_intercompany_invoices!
      unless current_admin_user.is_admin?
        return redirect_to admin_invoice_pass_path(resource), alert: "garden3d's invoices are made by an admin."
      end

      resource.make_trackers!

      made = 0
      failed = []
      InvoiceTracker.where(invoice_pass_id: resource.id, qbo_invoice_id: nil).order(:id).each do |tracker|
        tracker.make_invoice!
        made += 1
      rescue StandardError => e
        failed << "#{tracker.forecast_client.name}: #{e.message}"
      end

      summary = "Created #{made} draft(s) in QuickBooks."
      if failed.any?
        redirect_to admin_invoice_pass_path(resource), alert: "#{summary} Failed: #{failed.join(' | ')}".truncate(1500)
      else
        redirect_to admin_invoice_pass_path(resource), notice: summary
      end
    rescue StandardError => e
      redirect_to admin_invoice_pass_path(resource), alert: e.message
    end
  end

  action_item :rerun_invoice_pass, only: :show,
    if: proc { resource.enterprise == Enterprise.sanctuary } do
    link_to 'Send Reminders',
      rerun_invoice_pass_admin_invoice_pass_path(resource), method: :post
  end

  # Every pass generates its own invoices; what that means depends on the
  # enterprise. Sanctuary's come from Forecast. garden3d's are a $0.00 draft
  # per enterprise it bills, for Finance to fill in.
  action_item :rerun_invoice_pass_without_reminders, only: :show,
    if: proc { resource.forecast? || resource.intercompany? } do
    options = { method: :post }
    if resource.intercompany?
      options[:data] = {
        confirm: "Create a $0.00 draft invoice in garden3d's QuickBooks for each company that does not have one " \
                 "for #{resource.invoice_month}? Stacks first checks QuickBooks and skips any company that " \
                 "already has an invoice dated in this month.",
      }
    end
    link_to 'Generate Invoices', rerun_invoice_pass_without_reminders_admin_invoice_pass_path(resource), options
  end

  member_action :rerun_invoice_pass_without_reminders, method: :post do
    return make_intercompany_invoices! if resource.intercompany?

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

  action_item :refresh_intercompany_invoices, only: :show, if: proc { resource.intercompany? } do
    link_to "Refresh from QuickBooks", refresh_intercompany_invoices_admin_invoice_pass_path(resource), method: :post
  end

  # Computes every MSO executive's true-up for the month and records the run.
  # An admin's click and nothing else: no rake task or job calls it. It reads
  # the month's fee invoices from QuickBooks and writes nothing there.
  action_item :run_mso_compensation, only: :show,
    if: proc { current_admin_user.is_admin? && Mso::MonthlyRun.runnable?(resource) } do
    link_to "Run MSO compensation",
      run_mso_compensation_admin_invoice_pass_path(resource),
      method: :post,
      data: { confirm: "Compute MSO compensation for #{resource.invoice_month}? Stacks reads this month's " \
                       "management fee invoices from QuickBooks, checks them against account 4100, and " \
                       "writes each executive's true-up, dated the last day of the month. Running a month " \
                       "again replaces its figures." }
  end

  member_action :refresh_intercompany_invoices, method: :post do
    unless current_admin_user.is_admin?
      return redirect_to admin_invoice_pass_path(resource), alert: "garden3d's invoices are refreshed by an admin."
    end

    # What Stacks holds for these invoices is about to change. Whether the fee
    # is collected has to be confirmed again (Check collection, or a run).
    # Withdrawn BEFORE the refresh, so it is withdrawn however the refresh
    # ends: one that raises part-way may already have rewritten or detached
    # an invoice, and the stamp described them as they were.
    MsoSnapshot.unconfirm_collection!(resource.id)

    begin
      run = Mso::IntercompanyInvoices.refresh!(invoice_pass: resource)
    rescue Mso::IntercompanyInvoices::Error => e
      return redirect_to admin_invoice_pass_path(resource), alert: e.message
    end

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

  member_action :run_mso_compensation, method: :post do
    # Kept even though the pass page is itself admin-only to view.
    unless current_admin_user.is_admin?
      return redirect_to admin_invoice_pass_path(resource), alert: "MSO compensation is run by an admin."
    end

    begin
      snapshot = Mso::MonthlyRun.call(invoice_pass: resource, run_by: current_admin_user)
    rescue Mso::MonthlyRun::Refused => e
      # truncate: the flash lives in the session cookie, and a variance
      # message lists every invoice it compared.
      return redirect_to admin_invoice_pass_path(resource), alert: e.message.truncate(1200)
    end

    redirect_to admin_mso_snapshot_path(snapshot),
      notice: "MSO compensation for #{resource.invoice_month} has been computed. Nobody is paid until every " \
              "executive accepts and the fee is confirmed collected."
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
    if resource.intercompany?
      # No Forecast hours, no generator errors: this pass holds garden3d's
      # invoices to the enterprises it bills.
      render 'intercompany_pass', { invoice_pass: invoice_pass }
    else
      # Sanctuary's passes, and garden3d's passes from before
      # InvoicePass::INTERCOMPANY_START: rendered exactly as before.
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
