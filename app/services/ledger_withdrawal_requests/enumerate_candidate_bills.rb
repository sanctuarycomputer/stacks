module LedgerWithdrawalRequests
  # Walks every SyncsAsQboBill host attached to a ledger and returns one row
  # per linked Bill (with its candidacy state) — the selection screen renders
  # each, with grayed-out reasons for non-selectable rows.
  class EnumerateCandidateBills
    # Host classes to walk. Each row has #qbo_bill_id and a #payable? per
    # SyncsAsQboBill, and #amount.
    HOST_CLASSES = [
      ContributorPayout,
      ContributorAdjustment,
      ProfitShare,
      Trueup,
      PayStub,
    ].freeze

    Row = Struct.new(:host, :qbo_bill, :qbo_bill_id, :qbo_account_id, :amount, :selectable, :reason, :description, keyword_init: true)

    def self.call(ledger)
      new(ledger).call
    end

    def initialize(ledger)
      @ledger = ledger
    end

    def call
      claimed_bill_keys = open_request_bill_keys
      rows = collect_rows
      rows.map { |row| annotate_candidacy(row, claimed_bill_keys) }
    end

    private

    attr_reader :ledger

    def collect_rows
      HOST_CLASSES.flat_map do |klass|
        klass.where(ledger_id: ledger.id).map do |host|
          qbo_bill_id = host.qbo_bill_id
          qbo_account_id = host.qbo_account_for_bill&.id
          qbo_bill = (qbo_bill_id.present? && qbo_account_id.present?) ? host.qbo_bill : nil
          Row.new(
            host: host,
            qbo_bill: qbo_bill,
            qbo_bill_id: qbo_bill_id,
            qbo_account_id: qbo_account_id,
            amount: host.respond_to?(:amount) ? host.amount.to_f : 0,
            description: row_description(host),
            selectable: false,
            reason: nil,
          )
        end
      end
    end

    def annotate_candidacy(row, claimed_bill_keys)
      host = row.host

      if !host.payable?
        row.reason = "Not yet payable"
        return row
      end

      if row.qbo_bill_id.blank? || row.qbo_account_id.blank?
        row.reason = "Bill not yet pushed to QBO"
        return row
      end

      if row.qbo_bill.nil?
        row.reason = "QBO Bill mirror missing — wait for next sync"
        return row
      end

      if row.qbo_bill.paid?
        row.reason = "Already paid in QBO"
        return row
      end

      if claimed_bill_keys.include?([row.qbo_account_id, row.qbo_bill_id])
        row.reason = "Already in an open withdrawal request"
        return row
      end

      row.selectable = true
      row
    end

    # Bills already locked into a pending request on this ledger. Used to
    # gray those out on the selection screen so two requests can't claim
    # the same Bill.
    def open_request_bill_keys
      LedgerWithdrawalRequestBill
        .joins(:ledger_withdrawal_request)
        .where(ledger_withdrawal_requests: { ledger_id: ledger.id, processed_at: nil, cancelled_at: nil })
        .pluck(:qbo_account_id, :qbo_bill_id)
        .to_set
    end

    def row_description(host)
      type = host.class.name.titleize
      effective = host.respond_to?(:effective_on_for_display) ? host.effective_on_for_display : nil
      base = effective.present? ? "#{type} — #{effective}" : type
      host.respond_to?(:description) && host.description.present? ? "#{base}: #{host.description.to_s.truncate(60)}" : base
    end
  end
end
