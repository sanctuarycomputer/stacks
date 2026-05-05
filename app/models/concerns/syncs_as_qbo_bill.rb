module SyncsAsQboBill
  extend ActiveSupport::Concern

  # Host models are acts_as_paranoid: destroy soft-deletes the host row but
  # leaves it referencing qbo_bills via qbo_bill_id. A naive `dependent: :destroy`
  # on the belongs_to violates the FK because the soft-deleted host still points
  # at the bill. Detach first, then destroy — same ordering used in load_qbo_bill!.
  # Wire up via `before_destroy :detach_and_destroy_qbo_bill` on hosts that want
  # immediate cleanup (CP/CA). Trueup relies on cleanup_orphaned_qbo_objects! cron.
  def detach_and_destroy_qbo_bill
    return unless qbo_bill.present?

    ActiveRecord::Base.transaction do
      bill = qbo_bill
      update_attribute(:qbo_bill_id, nil)
      bill.destroy!
    end
  end

  def qbo_url
    qbo_bill.try(:qbo_url)
  end

  def find_qbo_account!(qbo_accounts = Stacks::Quickbooks.fetch_all_accounts)
    account = qbo_accounts.find{|a| a.name == "Contractors - Client Services"}
    studio = contributor.forecast_person.studio
    if studio.present?
      specific_account = qbo_accounts.find{|a| a.name == studio.qbo_subcontractors_categories.first}
      account = specific_account if specific_account.present?
    end
    raise "No account found in QuickBooks" unless account.present?
    [account, studio]
  end

  def load_qbo_bill!
    return nil unless qbo_bill.present?

    begin
      return Stacks::Quickbooks.fetch_bill_by_id(qbo_bill.qbo_id)
    rescue => e
      if e.message.starts_with?("Object Not Found:")
        ActiveRecord::Base.transaction do
          b = qbo_bill
          update_attribute(:qbo_bill_id, nil)
          self.reload
          b.destroy!
        end
      end
      return nil
    end
  end

  # Host models MUST implement:
  # - bill_txn_date → Date used for the QBO Bill's txn_date and due_date
  # - bill_description → String used as the QBO Bill line item description
  #   (conventionally a URL back to the Stacks admin page for the record)
  # - bill_doc_number_code → Short 2-char tag embedded in the QBO Bill doc_number so
  #   cleanup_orphaned_qbo_objects! can unambiguously map a QBO bill back to its
  #   host class. MUST be unique across all host models. Current mappings:
  #     ContributorPayout     → "CP"
  #     Trueup                → "TU"
  #     ContributorAdjustment → "CA"

  def payable?
    false
  end

  def sync_qbo_bill!
    return unless contributor.qbo_vendor.present?

    bill = load_qbo_bill! || Quickbooks::Model::Bill.new
    bill.txn_date = bill_txn_date
    bill.due_date = bill_txn_date
    bill.doc_number = "Stacks_#{id}_#{bill_doc_number_code}" # QBO has a 21 character limit; short code keeps us well under
    bill.vendor_ref = Quickbooks::Model::BaseReference.new(contributor.qbo_vendor.id)

    line_item = Quickbooks::Model::BillLineItem.new(
      description: bill_description,
      amount: amount,
    )

    account, studio = find_qbo_account!
    line_item.account_based_expense_item! do |detail|
      detail.account_ref = Quickbooks::Model::BaseReference.new(account.id)
    end

    bill.line_items = [line_item]
    bill_service = Quickbooks::Service::Bill.new
    bill_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
    bill_service.access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token
    bill = bill.id.present? ? bill_service.update(bill) : bill_service.create(bill)

    ActiveRecord::Base.transaction do
      existing_bill_tracker = QboBill.find_by(qbo_id: bill.id)
      if existing_bill_tracker.present?
        existing_bill_tracker.update!(data: bill.as_json)
      else
        qbo_bill_tracker = QboBill.create!(
          qbo_id: bill.id,
          data: bill.as_json,
          qbo_vendor_id: contributor.qbo_vendor.id
        )
      end
      update_attribute(:qbo_bill_id, bill.id)
      self.reload
    end
  end
end