module SyncsAsQboBill
  extend ActiveSupport::Concern

  def find_qbo_account!
    qbo_accounts = Stacks::Quickbooks.fetch_all_accounts
    account = qbo_accounts.find{|a| a.name == "[SC] Subcontractors"}
    studio = contributor.forecast_person.studio
    if studio.present?
      specific_account = qbo_accounts.find{|a| a.name == studio.qbo_subcontractors_categories.first}
      account = specific_account if specific_account.present?
    end
    raise "No account found in QuickBooks" unless account.present?
    account
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

  def find_invoice_pass!
    if defined?(invoice_pass)
      invoice_pass
    elsif defined?(invoice_tracker)
      invoice_tracker.invoice_pass
    else
      raise "No invoice pass defined"
    end
  end

  def sync_qbo_bill!
    return unless contributor.qbo_vendor.present?

    bill = load_qbo_bill! || Quickbooks::Model::Bill.new
    bill.txn_date = find_invoice_pass!.start_of_month.end_of_month
    bill.due_date = find_invoice_pass!.start_of_month.end_of_month
    bill.doc_number = "Stacks_#{id}_#{self.class.name}".truncate(21) # QBO has a 21 character limit for doc numbers
    bill.vendor_ref = Quickbooks::Model::BaseReference.new(contributor.qbo_vendor.id)

    description = 
      case self.class.name
        when "Trueup"
          "http://stacks.garden3d.net/admin/contributors/#{contributor.id}/trueups/#{id}"
        when "ContributorPayout"
          "https://stacks.garden3d.net/admin/invoice_trackers/#{invoice_tracker.id}/contributor_payouts/#{id}"
        else
          raise "Unknown class: #{self.class.name}"
        end

    line_item = Quickbooks::Model::BillLineItem.new(
      description: description,
      amount: amount,
    )

    line_item.account_based_expense_item! do |detail|
      detail.account_ref = Quickbooks::Model::BaseReference.new(find_qbo_account!.id)
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