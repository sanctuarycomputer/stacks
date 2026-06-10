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

  def detach_and_destroy_qbo_bill
    bill = qbo_bill
    return unless bill.present?
    ActiveRecord::Base.transaction do
      update_attribute(:qbo_bill_id, nil)
      bill.destroy!
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
  # - bill_line_item_key     → QboBillAccountMapping::LINE_ITEM_KEYS entry
  #   used by the default single-line bill_line_items below. Hosts that
  #   override bill_line_items (ContributorPayout, PayStub) resolve their
  #   own per-line keys instead.

  def payable?
    false
  end

  # Returns the array of Quickbooks::Model::BillLineItem objects that will
  # be pushed for this host's bill. Default implementation produces a single
  # line at the account resolved by the bill account mapping engine
  # (project tracker → contributor → entity default; raises
  # Qbo::UnmappedLineItemError when unmapped). ContributorPayout and
  # PayStub override this to emit multiple lines.
  def bill_line_items
    account = Qbo::BillAccountResolver.new(enterprise)
      .account_for(bill_line_item_key, contributor: contributor)
    line = Quickbooks::Model::BillLineItem.new(description: bill_description, amount: amount)
    line.account_based_expense_item! do |detail|
      detail.account_ref = Quickbooks::Model::BaseReference.new(account.qbo_id)
    end
    [line]
  end

  def sync_qbo_bill!
    qa = qbo_account_for_bill
    return if qa.nil?

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

    # Lazily prime the chart-of-accounts mirror on first use so a bill sync
    # works even before the daily task has run for this realm. (Previously
    # every sync did a live fetch_all_accounts here anyway.)
    qa.sync_all_chart_accounts! if QboChartAccount.where(qbo_account_id: qa.id).none?
    bill.line_items = bill_line_items
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
