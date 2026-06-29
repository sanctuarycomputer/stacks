module SyncsAsQboBill
  extend ActiveSupport::Concern

  # Hosts including this concern ALSO include LedgerItem, which delegates
  # :enterprise to :ledger. The concern routes QBO work through the
  # enterprise's qbo_account; if the enterprise has no connected QBO
  # account, all sync operations are no-ops.

  # The QboAccount this ledger item's bill belongs to.
  def qbo_account_for_bill
    enterprise&.qbo_account
  end

  # Lookup of the local QboBill record. The (qbo_account_id, qbo_id) pair is
  # unique post-scoping migration, so we have to scope by both — we removed
  # the old `belongs_to :qbo_bill` because primary_key: "qbo_id" can't express
  # composite scoping in AR 6.1.
  def qbo_bill
    return nil if qbo_bill_id.blank?
    qa = qbo_account_for_bill
    return nil if qa.nil?
    QboBill.find_by(qbo_account_id: qa.id, qbo_id: qbo_bill_id)
  end

  # Tearing down the local QboBill triggers QboBill#delete_qbo_bill! which
  # destroys the remote bill in QBO. Doing that on a PAID bill orphans the
  # QBO BillPayment (payment exists with no parent bill — corrupts vendor AP).
  # Refuse to proceed; operator must void the payment in QBO first. This guard
  # protects every SyncsAsQboBill host's before_destroy chain (Reimbursement,
  # ContributorPayout, etc.) AND the un-accept paths in admin actions.
  class PaidQboBillError < StandardError; end

  def detach_and_destroy_qbo_bill
    bill = qbo_bill
    return unless bill.present?

    # Refresh the bill against QBO before checking paid? — cached
    # data['balance'] may be stale (last sync_all_bills! could be hours ago,
    # and Finance might have paid the bill in QBO since). If we can fetch
    # fresh state, use it; if QBO is unreachable, fall back to cached.
    # Either way, refuse if the bill is paid (destroying a paid bill in QBO
    # orphans the BillPayment in vendor AP).
    fresh_balance =
      begin
        remote = load_qbo_bill!
        remote ? remote.try(:balance).to_f : nil
      rescue
        nil
      end

    paid = fresh_balance.present? ? fresh_balance <= 0 : bill.paid?
    if paid
      raise PaidQboBillError,
        "#{self.class.name} ##{id}: refusing to destroy QBO bill #{bill.qbo_id} — it is paid. Void the BillPayment in QBO first."
    end

    ActiveRecord::Base.transaction do
      update_attribute(:qbo_bill_id, nil)
      # Re-read the local QboBill in case load_qbo_bill!'s rescue path nulled
      # qbo_bill_id (Object Not Found) — bill would then be a stale reference.
      bill = QboBill.find_by(qbo_account_id: qbo_account_for_bill&.id, qbo_id: bill.qbo_id)
      bill&.destroy!
    end
  end

  def qbo_url
    qbo_bill.try(:qbo_url)
  end

  def load_qbo_bill!
    return nil if qbo_bill_id.blank?
    qa = qbo_account_for_bill
    return nil if qa.nil?

    begin
      return qa.fetch_bill_by_id(qbo_bill_id)
    rescue => e
      if e.message.starts_with?("Object Not Found:")
        # Mirror the cleanup we used to do via load_qbo_bill!
        ActiveRecord::Base.transaction do
          local = qbo_bill
          update_attribute(:qbo_bill_id, nil)
          self.reload
          local.destroy! if local
        end
      end
      return nil
    end
  end

  # Host models MUST implement:
  # - bill_txn_date          → Date for QBO Bill txn_date and due_date
  # - bill_description       → String used as the line item description
  # - bill_doc_number_code   → Short 2-char tag in the QBO Bill doc_number
  #   (must be unique across all host models). Current mappings:
  #     CP = ContributorPayout, TU = Trueup, CA = ContributorAdjustment,
  #     PS = ProfitShare, SB = PayStub.

  def payable?
    false
  end

  # Contribution to qbo_bound balance. Uses the QBO bill's remaining unpaid
  # balance when a bill exists so partial payments are reflected one-to-one
  # with QBO's vendor AP. Falls back to the host amount when there's no
  # synced bill OR when the bill's data doesn't carry a balance (otherwise
  # an incomplete sync would silently zero the contributor's qbo_bound
  # balance).
  def qbo_bound_balance_amount
    qb = qbo_bill
    return amount.to_f if qb.nil?
    qb.remaining_balance || amount.to_f
  end

  def sync_qbo_bill!(accounts_cache: nil)
    qa = qbo_account_for_bill
    return if qa.nil?
    accounts_cache ||= Qbo::AccountsCache.new

    vendor = contributor.qbo_vendor_for(qa)
    return if vendor.nil?

    # QBO Bills reject amounts <= 0 ("Enter a transaction amount that is 0 or
    # greater"). ContributorAdjustment rows folded from the old MiscPayment
    # table carry negative amounts (representing deductions from the
    # contributor's ledger balance) and shouldn't manifest as QBO bills.
    # PayStubs / CPs / Trueups / ProfitShares are always positive, so this
    # guard is a no-op for them.
    return if amount.to_f <= 0

    bill = load_qbo_bill! || Quickbooks::Model::Bill.new
    bill.txn_date = bill_txn_date
    bill.due_date = bill_txn_date
    bill.doc_number = "Stacks_#{id}_#{bill_doc_number_code}" # QBO has a 21-char limit
    bill.vendor_ref = Quickbooks::Model::BaseReference.new(vendor.qbo_id)

    bill.line_items = Qbo::BillRouter.new(self, accounts_cache: accounts_cache).lines.map do |data|
      line = Quickbooks::Model::BillLineItem.new(description: data[:description], amount: data[:amount])
      line.account_based_expense_item! do |detail|
        detail.account_ref = Quickbooks::Model::BaseReference.new(data[:account].id)
      end
      line
    end
    bill_service = Quickbooks::Service::Bill.new
    bill_service.company_id = qa.realm_id
    bill_service.access_token = qa.make_and_refresh_qbo_access_token
    bill = bill.id.present? ? bill_service.update(bill) : bill_service.create(bill)

    ActiveRecord::Base.transaction do
      existing = QboBill.find_by(qbo_account_id: qa.id, qbo_id: bill.id)
      if existing.present?
        existing.update!(data: bill.as_json)
      else
        QboBill.create!(
          qbo_id: bill.id,
          qbo_account_id: qa.id,
          data: bill.as_json,
          qbo_vendor_id: vendor.qbo_id,
        )
      end
      update_attribute(:qbo_bill_id, bill.id)
      self.reload
    end
  end
end
