ActiveAdmin.register ContributorPayout do
  config.filters = false
  config.paginate = false
  actions :index, :new, :show, :edit, :update, :create, :destroy
  permit_params :amount, :description, :created_by_id, :blueprint, :skip_seventy_percent_check
  menu false

  belongs_to :invoice_tracker

  action_item :make_payouts, only: :index, if: proc { current_admin_user.is_admin? } do
    link_to "Calculate Default Payouts", make_payouts_admin_invoice_tracker_contributor_payouts_path(invoice_tracker),
      method: :post,
      data: { confirm: "Are you sure you want to re-calculate the payouts for this invoice? This will delete/overwrite any custom payouts previously configured." }
  end

  # The breakdown shown after make_payouts refused to write. It re-runs the
  # check here rather than carrying the result across the redirect; the modal
  # is position: fixed, so it covers the page from wherever it is rendered.
  action_item :margin_breach, only: :index, if: proc { params[:margin_breach].present? && current_admin_user.is_admin? } do
    check =
      begin
        # `retained` carries the earlier payouts a write just found it could
        # not remove, when that is what put the invoice over its cap.
        retained_ids = params[:retained].to_s.split(",").map(&:to_i).presence
        candidate = InvoicePayouts::MarginCheck.new(InvoicePayouts::Build.new(invoice_tracker, retained_orphan_ids: retained_ids)) if invoice_tracker.qbo_invoice.present?
        candidate if candidate&.breached? && candidate.rows
      rescue StandardError => e
        Rails.logger.error("[contributor_payouts_margin_breach] it=#{invoice_tracker.id}: #{e.class}: #{e.message}")
        nil
      end
    render(partial: "admin/contributor_payouts/margin_breach", locals: { check: check, invoice_tracker: invoice_tracker, retained: params[:retained].presence }) if check
  end

  action_item :toggle_acceptance, only: :show do
    # The button posts to the payout's invoice tracker, so it is offered only
    # to someone that tracker would let through (never a non-admin on one of
    # garden3d's trackers).
    if (current_admin_user == resource.contributor.forecast_person.admin_user || current_admin_user.is_admin?) &&
       authorized?(:toggle_contributor_payout_acceptance, resource.invoice_tracker)
      link_to resource.accepted? ? "Unaccept" : "Accept", toggle_contributor_payout_acceptance_admin_invoice_pass_invoice_tracker_path(resource.invoice_tracker.invoice_pass.id, resource.invoice_tracker, {contributor_payout_id: resource.id}),
        method: :post
    end
  end

  action_item :sync_qbo_bill, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to "Sync QBO Bill", sync_qbo_bill_admin_invoice_tracker_contributor_payout_path(resource.invoice_tracker, resource),
      method: :post
  end

  action_item :migrate_blueprint, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to "Migrate Blueprint",
      migrate_blueprint_admin_invoice_tracker_contributor_payout_path(resource.invoice_tracker, resource),
      method: :post,
      data: { confirm: "Migrate this payout's blueprint to the slim shape? This drops the redundant qbo_line_item blob and unused blueprint_metadata fields. Idempotent — safe to re-run." }
  end

  member_action :sync_qbo_bill, method: :post do
    cp = ContributorPayout.find(params[:id])
    cp.sync_qbo_bill!
    return redirect_to(
      admin_invoice_tracker_contributor_payout_path(cp.invoice_tracker, cp),
      notice: "Success",
    )
  end

  member_action :remap_blueprint_entry, method: :post do
    return redirect_to(
      admin_invoice_tracker_contributor_payout_path(resource.invoice_tracker, resource),
      alert: "Admins only."
    ) unless current_admin_user.is_admin?

    begin
      resource.remap_blueprint_entry!(
        role: params[:role],
        index: params[:index].to_i,
        new_line_item_id: params[:new_line_item_id]
      )
    rescue => e
      return redirect_to(
        admin_invoice_tracker_contributor_payout_path(resource.invoice_tracker, resource),
        alert: "Remap failed: #{e.message}"
      )
    end

    redirect_to(
      admin_invoice_tracker_contributor_payout_path(resource.invoice_tracker, resource),
      notice: "Remapped #{params[:role]} ##{params[:index]} to QBO line ##{params[:new_line_item_id]}."
    )
  end

  member_action :migrate_blueprint, method: :post do
    return redirect_to(
      admin_invoice_tracker_contributor_payout_path(resource.invoice_tracker, resource),
      alert: "Admins only."
    ) unless current_admin_user.is_admin?

    before_bp = resource.read_attribute(:blueprint)
    before_size = before_bp.is_a?(Hash) ? before_bp.to_json.bytesize : 0

    begin
      changed = resource.slim_blueprint!
    rescue => e
      return redirect_to(
        admin_invoice_tracker_contributor_payout_path(resource.invoice_tracker, resource),
        alert: "Migration aborted: #{e.message}"
      )
    end

    if changed
      after_size = resource.reload.read_attribute(:blueprint).to_json.bytesize
      return redirect_to(
        admin_invoice_tracker_contributor_payout_path(resource.invoice_tracker, resource),
        notice: "Blueprint migrated — #{before_size} B → #{after_size} B (saved #{before_size - after_size} B)."
      )
    else
      return redirect_to(
        admin_invoice_tracker_contributor_payout_path(resource.invoice_tracker, resource),
        notice: "Blueprint is already in slim shape — nothing to do."
      )
    end
  end

  member_action :toggle_acceptance, method: :post do
    cp = ContributorPayout.find(params[:id])
    return unless cp.contributor.forecast_person.try(:admin_user) == current_admin_user || current_admin_user.is_admin?
    cp.toggle_acceptance!
    return redirect_to(
      admin_invoice_tracker_contributor_payouts_path(cp.invoice_tracker, cp, format: :html),
      notice: "Success",
    )
  end

  collection_action :make_payouts, method: :post do
    invoice_tracker = InvoiceTracker.find(params["invoice_tracker_id"])
    index_path = admin_invoice_tracker_contributor_payouts_path(invoice_tracker)
    return redirect_to(index_path, alert: "Admins only.") unless current_admin_user.is_admin?
    if invoice_tracker.garden3d?
      return redirect_to(index_path, alert: "garden3d's intercompany invoices have no contributor payouts.")
    end

    begin
      if invoice_tracker.qbo_invoice.nil?
        return redirect_to(index_path, alert: "This invoice has no QBO invoice yet, so there is nothing to pay out.")
      end

      # Rule on the whole invoice before writing anything. Over the cap, the
      # index re-runs this check and shows the breakdown; an admin can then
      # come back here with a reason to generate regardless.
      # Coming back from a write that found unremovable earlier payouts, the
      # breakdown the admin saw (and is now answering) counted them.
      retained_ids = params[:retained].to_s.split(",").map(&:to_i).presence
      build = InvoicePayouts::Build.new(invoice_tracker, retained_orphan_ids: retained_ids)
      check = InvoicePayouts::MarginCheck.new(build)
      # Whoever is really signed in, not someone they are impersonating:
      # this is the name that goes on the payouts and on any override.
      generating_admin = true_admin_user

      if check.breached?
        breach_path = admin_invoice_tracker_contributor_payouts_path(invoice_tracker, { margin_breach: 1, retained: params[:retained].presence }.compact)
        return redirect_to(breach_path) unless ActiveModel::Type::Boolean.new.cast(params[:force])

        reason = params[:override_reason].to_s.strip
        return redirect_to(breach_path, alert: "A reason is required to generate payouts over the cap.") if reason.blank?

        ActiveRecord::Base.transaction do
          invoice_tracker.make_contributor_payouts!(generating_admin, build: build, allow_over_cap: true)
          # The note quotes what was written, which is not always what the
          # pre-flight judged: generation finds out for real which earlier
          # payouts it can remove. Within the cap after all, nothing was
          # overridden, so there is nothing to note.
          written = InvoicePayouts::MarginCheck.new(invoice_tracker.written_payout_build)
          if written.breached?
            override_note = "[#{Date.today.iso8601}] #{generating_admin.email} generated payouts over the cap (#{written.payout_percentage}% vs #{written.cap_percentage}%): #{reason}"
            invoice_tracker.update!(notes: [invoice_tracker.notes.presence, override_note].compact.join("\n\n"))
            invoice_tracker.record_payout_cap_override!(admin_user: generating_admin, reason: reason, check: written)
          else
            invoice_tracker.clear_payout_cap_override!
          end
        end
      else
        ActiveRecord::Base.transaction do
          invoice_tracker.make_contributor_payouts!(generating_admin, build: build)
          # Within the cap now, so an earlier override no longer describes
          # the payouts on this invoice.
          invoice_tracker.clear_payout_cap_override!
        end
      end

      redirect_to index_path, notice: "Payouts processed!"
    rescue InvoiceTracker::PayoutsOverCapError => e
      # The pre-flight passed on the cached QBO bills; the write learned
      # otherwise and rolled back. Show the breakdown with those payouts
      # counted, where the admin can still generate with a reason.
      Rails.logger.error("[contributor_payouts_make_payouts] it=#{invoice_tracker.id}: #{e.message}")
      redirect_to admin_invoice_tracker_contributor_payouts_path(invoice_tracker, margin_breach: 1, retained: e.survivor_ids.join(",")),
        alert: "Could not generate payouts: #{e.message}"
    rescue StandardError => e
      Rails.logger.error("[contributor_payouts_make_payouts] it=#{invoice_tracker.id}: #{e.class}: #{e.message}")
      redirect_to index_path, alert: "Could not generate payouts: #{e.message.to_s.lines.first.to_s.strip}"
    end
  end

  controller do
    before_action :authorize_garden3d_tracker!

    def scoped_collection
      super.with_deleted.includes(ledger: { contributor: :forecast_person })
    end

    # A tracker on garden3d's pass is admin-only, and so are the payouts
    # pages under it: the rule is AdminAuthorization's. It is asked here of
    # the tracker, before anything else runs, because ActiveAdmin authorizes
    # the index and the collection actions against the ContributorPayout
    # class alone, and does not authorize a member action that never loads
    # its payout (toggle_acceptance, sync_qbo_bill).
    #
    # The tracker is taken from the payout as well as from the URL: the
    # index's own Accept link passes the payout's id where the tracker's
    # belongs.
    #
    # `show` is left to the usual per-payout check, which lets a contributor
    # read their own payout and nobody else's.
    def authorize_garden3d_tracker!
      payout = ContributorPayout.with_deleted.find_by(id: params[:id]) if params[:id].present?
      tracker = [payout&.invoice_tracker, InvoiceTracker.find_by(id: params[:invoice_tracker_id])]
        .compact.find(&:garden3d?)
      return if tracker.nil?
      return if action_name == "show" && payout.present?

      authorize!(:read, tracker)
    end

    def build_new_resource
      contributor_id = params.dig(:contributor_payout, :contributor_id)
      cp = ContributorPayout.new(permitted_params[:contributor_payout] || {})
      if contributor_id.present?
        contributor = Contributor.unscoped.find(contributor_id)
        invoice_tracker = parent
        ledger = Ledger.find_or_create_for(
          enterprise: invoice_tracker.forecast_client.billing_enterprise,
          contributor: contributor
        )
        cp.ledger = ledger
      end
      cp
    end

    def create
      params[:contributor_payout]["created_by_id"] = current_admin_user.id
      params[:contributor_payout]["blueprint"] = {}
      strip_admin_only_params
      super
    end

    def update
      strip_admin_only_params
      super
    end

    # The form only shows this box to admins, but hiding an input enforces
    # nothing: permit_params is one list for everyone.
    def strip_admin_only_params
      return if current_admin_user.is_admin?
      params[:contributor_payout]&.delete(:skip_seventy_percent_check)
      # A hand-written Commission entry is subtracted from the pool the cap
      # is checked against, so the raw blueprint is admin-only too.
      params[:contributor_payout]&.delete(:blueprint) if action_name == "update"
    end

    # Catch the SyncsAsQboBill paid-bill guard so 'Delete' on a CP whose QBO
    # bill is already paid surfaces a clean flash instead of a 500.
    def destroy
      super
    rescue SyncsAsQboBill::PaidQboBillError => e
      Rails.logger.error("[contributor_payout_destroy] cp=#{params[:id]}: #{e.message}")
      redirect_to admin_invoice_tracker_contributor_payouts_path(parent),
        alert: "Cannot delete: linked QBO bill is paid. Void the BillPayment in QBO first, then retry."
    end
  end

  index download_links: false do
    column :status do |cp|
      span(cp.status.to_s.humanize, class: "pill #{cp.status}")
    end
    column :contributor
    column :as_account_lead do |cp|
      number_to_currency(cp.as_account_lead)
    end
    column :as_project_lead do |cp|
      number_to_currency(cp.as_project_lead)
    end
    column :as_ic do |cp|
      number_to_currency(cp.as_individual_contributor)
    end
    column :amount do |cp|
      number_to_currency(cp.amount)
    end
    column :created_by
    column :accepted?

    actions do |resource|
      if resource.contributor.forecast_person.try(:admin_user) == current_admin_user || current_admin_user.is_admin?
        if resource.accepted?
          link_to(
            "Unaccept",
            toggle_acceptance_admin_invoice_tracker_contributor_payout_path(resource.id, resource),
            method: :post
          )
        else
          link_to(
            "Accept",
            toggle_acceptance_admin_invoice_tracker_contributor_payout_path(resource.id, resource),
            method: :post
          )
        end
      end
    end
  end

  form do |f|
    f.inputs do
      f.semantic_errors
      f.input :invoice_tracker, input_html: { disabled: true }
      f.input :contributor, input_html: { disabled: f.object.persisted? }
      f.input :amount
      f.input :description

      # Only show the blueprint editor if the user is an admin
      if current_admin_user.is_admin?
        f.input :skip_seventy_percent_check,
          as: :boolean,
          label: "Skip payout cap validation (one-time override, not persisted)",
          hint: "Tick this to let this save proceed even if all contributor payouts on this invoice would exceed the invoice's payout cap. Only use when you understand why the cap is blocking an otherwise correct edit."
        f.input :blueprint, as: :json_editor, input_html: { style: { height: "600px" } }
      end
    end

    f.actions
  end

  show do
    render(partial: 'show', locals: {
      resource: resource
    })
  end
end
