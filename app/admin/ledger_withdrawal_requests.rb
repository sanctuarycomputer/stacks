ActiveAdmin.register LedgerWithdrawalRequest do
  menu label: "Withdrawal Requests", parent: "Money"
  config.filters = false
  actions :index, :new, :create, :show

  scope :pending, default: true
  scope "Paid", :processed
  scope :cancelled

  permit_params :ledger_id, :notes, bills_attributes: [:qbo_account_id, :qbo_bill_id, :amount_snapshot]

  action_item :process_via_qbo, only: :show, if: proc { resource.pending? && current_admin_user.is_admin? } do
    url = qbo_vendor_url_for(resource)
    if url.present?
      link_to "Open Vendor in QBO ↗", url, target: "_blank", rel: "noopener"
    else
      msg = "No QBO vendor mapped for this contributor on #{resource.enterprise.name}"
      link_to "Open Vendor in QBO ↗", "#", onclick: "alert(#{msg.to_json}); return false;"
    end
  end

  action_item :cancel, only: :show, if: proc { resource.pending? && current_admin_user.is_admin? } do
    # Browser-prompt for the reason so the controller doesn't have to bounce
    # through a separate form just to capture one string. JS submits the
    # reason as a form param via a synthesized POST.
    confirm_msg = "Cancel this withdrawal request? The bills go back to selectable for the contributor."
    cancel_url = cancel_admin_ledger_withdrawal_request_path(resource)
    link_to "Cancel Request", "#", onclick: <<~JS.html_safe
      (function(){
        if (!confirm(#{confirm_msg.to_json})) return false;
        var reason = prompt("Reason for cancelling? (optional)");
        if (reason === null) return false;
        var token = document.querySelector('meta[name="csrf-token"]').getAttribute('content');
        var form = document.createElement('form');
        form.method = 'post';
        form.action = #{cancel_url.to_json};
        var t = document.createElement('input'); t.type = 'hidden'; t.name = 'authenticity_token'; t.value = token; form.appendChild(t);
        if (reason) { var r = document.createElement('input'); r.type = 'hidden'; r.name = 'reason'; r.value = reason; form.appendChild(r); }
        document.body.appendChild(form); form.submit();
        return false;
      })(); return false;
    JS
  end

  member_action :process_via_deel, method: :post do
    LedgerWithdrawalRequests::ProcessViaDeel.call(
      request: resource,
      processed_by: current_admin_user,
      contract_id: params.require(:contract_id),
      description: params[:description].to_s,
      amount: params[:amount].presence,
      date_submitted: params[:date_submitted].presence || Date.current,
      allow_overpayment: ActiveModel::Type::Boolean.new.cast(params[:allow_overpayment]),
    )
    redirect_to admin_ledger_withdrawal_request_path(resource), notice: "Processed via Deel."
  rescue LedgerWithdrawalRequests::ProcessViaDeel::Error => e
    redirect_to admin_ledger_withdrawal_request_path(resource), alert: e.message
  end

  member_action :cancel, method: :post do
    resource.update!(
      cancelled_at: Time.current,
      cancelled_by: current_admin_user,
      cancelled_reason: params[:reason].to_s.presence,
    )
    redirect_to admin_ledger_withdrawal_request_path(resource), notice: "Request cancelled."
  end

  controller do
    helper_method :enumerate_candidates_for, :contributor_owns_ledger?, :qbo_vendor_url_for

    before_action :require_ledger_param, only: [:new]
    before_action :verify_ledger_access!, only: [:new, :create]
    before_action :verify_qbo_vendor_mapping!, only: [:new, :create]
    before_action :require_admin_for_processing!, only: [:process_via_deel, :cancel]

    # Fail fast (with a friendly screen, not a redirect) when the contributor
    # has no ContributorQboVendor for the ledger's enterprise QBO account.
    # Withdrawal requests can only resolve into Bills that need to be paid
    # against a specific vendor; without that mapping nothing downstream
    # will work and the form would only produce a confusing dead end.
    def verify_qbo_vendor_mapping!
      ledger_id = params[:ledger_id] || params.dig(:ledger_withdrawal_request, :ledger_id)
      ledger = Ledger.find_by(id: ledger_id)
      return if ledger.nil?

      qa = ledger.enterprise.qbo_account
      vendor = qa && ledger.contributor.qbo_vendor_for(qa)
      return if vendor.present?

      @missing_vendor_ledger = ledger
      @missing_vendor_qbo_account = qa
      render :missing_qbo_vendor, layout: "active_admin", status: :unprocessable_entity
    end

    def require_admin_for_processing!
      return if current_admin_user.is_admin?
      redirect_to admin_ledger_withdrawal_request_path(resource), alert: "Only Stacks admins can process or cancel requests."
    end

    # Best-effort deep link to the connected QBO vendor record for this
    # ledger's contributor. Used by the "Process via QBO" action.
    def qbo_vendor_url_for(request)
      qa = request.enterprise.qbo_account
      return nil if qa.nil?
      vendor = request.contributor.qbo_vendor_for(qa)
      return nil if vendor.nil?
      "https://qbo.intuit.com/app/vendordetail?nameId=#{vendor.qbo_id}"
    end

    def require_ledger_param
      return if params[:ledger_id].present?
      redirect_to admin_root_path, alert: "A ledger must be selected before submitting a withdrawal request."
    end

    def verify_ledger_access!
      ledger_id = params[:ledger_id] || params.dig(:ledger_withdrawal_request, :ledger_id)
      return redirect_to(admin_root_path, alert: "Ledger not specified.") if ledger_id.blank?

      ledger = Ledger.find_by(id: ledger_id)
      return redirect_to(admin_root_path, alert: "Ledger not found.") if ledger.nil?

      return if current_admin_user.is_admin?
      return if contributor_owns_ledger?(ledger)

      redirect_to admin_root_path, alert: "You cannot submit withdrawals for that ledger."
    end

    def contributor_owns_ledger?(ledger)
      fp = current_admin_user.forecast_person
      return false if fp.nil?
      ledger.contributor_id == fp.contributor&.id
    end

    def enumerate_candidates_for(ledger)
      LedgerWithdrawalRequests::EnumerateCandidateBills.call(ledger)
    end

    # Pre-set the ledger from the URL param so AA's form DSL has access to it.
    def build_resource
      resource = super
      ledger_id = params[:ledger_id] || params.dig(:ledger_withdrawal_request, :ledger_id)
      resource.ledger ||= Ledger.find_by(id: ledger_id) if ledger_id.present?
      resource
    end

    def create
      ledger = Ledger.find(params.dig(:ledger_withdrawal_request, :ledger_id))
      selected_keys = Array(params.dig(:ledger_withdrawal_request, :selected_bill_keys)).reject(&:blank?)

      if selected_keys.empty?
        @ledger = ledger
        @candidates = enumerate_candidates_for(ledger)
        @ledger_withdrawal_request = LedgerWithdrawalRequest.new(ledger: ledger)
        flash.now[:alert] = "Select at least one bill to request payment for."
        render :new, status: :unprocessable_entity
        return
      end

      # Re-resolve every selected (qbo_account_id, qbo_bill_id) against the
      # candidate list — never trust the form's amount field for a value we
      # snapshot. This also drops anything the contributor selected but is no
      # longer selectable (paid in QBO between page load and submit, etc).
      candidates_by_key = enumerate_candidates_for(ledger).index_by { |r| "#{r.qbo_account_id}:#{r.qbo_bill_id}" }
      valid_rows = selected_keys.filter_map { |key| candidates_by_key[key] }.select(&:selectable)

      if valid_rows.empty?
        redirect_to(new_admin_ledger_withdrawal_request_path(ledger_id: ledger.id),
          alert: "None of the selected bills are still eligible. Try again.")
        return
      end

      req = LedgerWithdrawalRequest.create!(
        ledger: ledger,
        requested_at: Time.current,
        notes: params.dig(:ledger_withdrawal_request, :notes),
        bills_attributes: valid_rows.map { |r| { qbo_account_id: r.qbo_account_id, qbo_bill_id: r.qbo_bill_id, amount_snapshot: r.amount } },
      )

      redirect_to admin_ledger_withdrawal_request_path(req), notice: "Withdrawal request submitted."
    end

    def scoped_collection
      super.includes(:ledger, :enterprise, :contributor, bills: :qbo_account)
    end
  end

  index download_links: false do
    column :contributor do |r|
      r.contributor.forecast_person&.email || "Contributor ##{r.contributor.id}"
    end
    column :enterprise do |r|
      r.enterprise.name
    end
    column "Bills", &:bills
    column "Total" do |r|
      number_to_currency(r.total_amount)
    end
    column :requested_at
    column :status do |r|
      if r.cancelled?
        status_tag("Cancelled")
      elsif r.processed?
        status_tag("Processed (#{r.paid_via})")
      else
        status_tag("Pending")
      end
    end
    actions
  end

  show do
    render partial: "show", locals: { resource: resource }
  end

  form do |f|
    ledger = f.object.ledger
    if ledger.nil?
      panel "Pick a ledger first" do
        para "Open this form from a contributor's ledger tab so we know which enterprise to bill against."
      end
    else
      candidates = LedgerWithdrawalRequests::EnumerateCandidateBills.call(ledger)
        .select(&:selectable)
        .sort_by { |r| [r.effective_on || Date.new(1970, 1, 1), r.qbo_bill_id.to_s] }
        .reverse

      if candidates.empty?
        # No bills available — render the shared message panel (same chrome
        # as the missing-QBO-vendor screen) instead of the AA panel default.
        # No Notes input, no submit button — there's nothing to submit.
        render partial: "admin/ledger_withdrawal_requests/message_panel", locals: {
          title: "📭 Nothing to request right now",
          paragraphs: [
            "No bills on your #{ledger.enterprise.name} ledger are ready to request payment for yet.",
            "Anything that's not yet payable (e.g. waiting on cycle approval), already paid in QuickBooks, or already included in another open request won't show up here. Once a new bill becomes payable, come back and submit a request.",
          ],
          back_path: admin_contributor_path(ledger.contributor, ledger: ledger.id),
        }
      else
        f.semantic_errors

        # Reach for the same dashboard-modules / module-header / module-body
        # / index_table HTML the rest of Stacks uses (see the Contributor
        # ledger view) so the chrome here matches without us trying to skin
        # AA's .panel and fieldset chrome from the outside.
        render partial: "admin/ledger_withdrawal_requests/intro_panel", locals: { ledger: ledger }

        f.input :ledger_id, as: :hidden, input_html: { value: ledger.id }

        render partial: "admin/ledger_withdrawal_requests/bills_panel", locals: { candidates: candidates }

        render partial: "admin/ledger_withdrawal_requests/notes_panel", locals: { f: f }

        # Initial label reflects "everything selected" (the default state on
        # first render). JS in _bills_panel keeps it in sync as the user
        # toggles rows.
        initial_total = candidates.sum(&:amount)
        f.actions do
          f.action :submit,
            label: "Submit Withdrawal Request for #{number_to_currency(initial_total)}"
          f.cancel_link(admin_contributor_path(ledger.contributor))
        end
      end
    end
  end
end
