ActiveAdmin.register LedgerWithdrawalRequest do
  menu label: "Withdrawal Requests", parent: "Money"
  config.filters = false
  actions :index, :new, :create, :show

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

  action_item :mark_processed_manual, only: :show, if: proc { resource.pending? && current_admin_user.is_admin? } do
    link_to "Mark Processed",
      mark_processed_admin_ledger_withdrawal_request_path(resource),
      method: :post,
      data: { confirm: "Mark this request processed without changing any bills?" }
  end

  action_item :cancel, only: :show, if: proc { resource.pending? && current_admin_user.is_admin? } do
    link_to "Cancel Request", cancel_admin_ledger_withdrawal_request_path(resource), method: :post,
      data: { confirm: "Cancel this withdrawal request? Bills go back to selectable for the contributor." }
  end

  member_action :process_via_deel, method: :post do
    LedgerWithdrawalRequests::ProcessViaDeel.call(
      request: resource,
      processed_by: current_admin_user,
      contract_id: params.require(:contract_id),
      description: params[:description].to_s,
      date_submitted: params[:date_submitted].presence || Date.current,
    )
    redirect_to admin_ledger_withdrawal_request_path(resource), notice: "Processed via Deel."
  rescue LedgerWithdrawalRequests::ProcessViaDeel::Error => e
    redirect_to admin_ledger_withdrawal_request_path(resource), alert: e.message
  end

  member_action :mark_processed, method: :post do
    resource.update!(processed_at: Time.current, paid_via: LedgerWithdrawalRequest::PAID_VIA_MANUAL)
    redirect_to admin_ledger_withdrawal_request_path(resource), notice: "Marked processed."
  end

  member_action :cancel, method: :post do
    resource.update!(
      cancelled_at: Time.current,
      cancelled_by: current_admin_user,
      cancelled_reason: params[:reason].to_s.presence || "Cancelled by admin",
    )
    redirect_to admin_ledger_withdrawal_request_path(resource), notice: "Request cancelled."
  end

  controller do
    helper_method :enumerate_candidates_for, :contributor_owns_ledger?, :qbo_vendor_url_for

    before_action :require_ledger_param, only: [:new]
    before_action :verify_ledger_access!, only: [:new, :create]
    before_action :require_admin_for_processing!, only: [:process_via_deel, :process_manual, :cancel]

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

    def new
      ledger = Ledger.find(params[:ledger_id])
      @ledger = ledger
      @candidates = enumerate_candidates_for(ledger)
      @ledger_withdrawal_request = LedgerWithdrawalRequest.new(ledger: ledger)
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
end
