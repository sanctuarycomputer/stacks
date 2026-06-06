ActiveAdmin.register LedgerWithdrawalRequest do
  menu label: "Withdrawal Requests", parent: "Money"
  config.filters = false
  actions :index, :new, :create, :show

  permit_params :ledger_id, :notes, bills_attributes: [:qbo_account_id, :qbo_bill_id, :amount_snapshot]

  controller do
    helper_method :enumerate_candidates_for, :contributor_owns_ledger?

    before_action :require_ledger_param, only: [:new]
    before_action :verify_ledger_access!, only: [:new, :create]

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
