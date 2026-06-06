module LedgerWithdrawalRequests
  # Resolves a pending request by creating one Deel invoice adjustment for
  # the request's total amount. Mirror of the manual Deel withdrawal flow,
  # but driven from the controller's "Process via Deel" button on a
  # request show page rather than a per-row form.
  #
  # Doesn't touch the underlying QBO Bills' Paid state — that's a
  # follow-up. Once shipped, this service should additionally POST a
  # BillPayment per Bill to keep QBO accounting in sync.
  class ProcessViaDeel
    class Error < StandardError; end

    def self.call(**kwargs)
      new(**kwargs).call
    end

    def initialize(request:, processed_by:, contract_id:, description:, date_submitted: Date.current)
      @request = request
      @processed_by = processed_by
      @contract_id = contract_id.to_s
      @description = description.to_s
      @date_submitted = date_submitted
    end

    def call
      raise Error, "Request is not pending" unless @request.pending?

      adjustment = Contributors::SubmitDeelInvoiceAdjustment.call(
        contributor: @request.contributor,
        ledger: @request.ledger,
        contract_id: @contract_id,
        amount: @request.total_amount,
        description: @description.presence || "Stacks withdrawal request ##{@request.id}",
        date_submitted: @date_submitted,
        skip_balance_validation: @processed_by&.is_admin? || false,
      )

      @request.update!(
        processed_at: Time.current,
        paid_via: LedgerWithdrawalRequest::PAID_VIA_DEEL,
        deel_invoice_adjustment_id: adjustment.id,
      )

      adjustment
    rescue Contributors::SubmitDeelInvoiceAdjustment::Error => e
      raise Error, e.message
    end
  end
end
