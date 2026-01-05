class ContributorPayout < ApplicationRecord
  acts_as_paranoid

  belongs_to :invoice_tracker
  belongs_to :contributor
  belongs_to :forecast_person, class_name: "ForecastPerson", foreign_key: "forecast_person_id", primary_key: "forecast_id", optional: true
  belongs_to :created_by, class_name: 'AdminUser'
  belongs_to :qbo_bill, class_name: "QboBill", foreign_key: "qbo_bill_id", primary_key: "qbo_id", optional: true

  validates :amount, presence: true
  validate :contributor_payouts_within_seventy_percent
  validate :only_after_new_deal

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

  def calculate_surplus
    return [] unless in_sync?

    qbo_inv = invoice_tracker.qbo_invoice
    return [] unless qbo_inv.present?
    
    project_trackers = invoice_tracker.project_trackers

    blueprint["IndividualContributor"].map do |ic|
      qbo_line_item = qbo_inv.line_items.find{|li| li["id"] == ic.dig("blueprint_metadata", "id")} || {}
      amount_paid = ic.dig("amount").try(:to_f) || 0
      amount_billed = qbo_line_item.dig("amount").try(:to_f) || 0
      profit_margin = (amount_billed - amount_paid) / amount_billed
      surplus = ((profit_margin - 0.43) * amount_billed).round(2)
      surplus = 0 if surplus <= 0

      project_tracker = project_trackers.find{|pt| pt.forecast_project_ids.include?(ic.dig("blueprint_metadata", "forecast_project"))}
      {
        project_tracker: project_tracker,
        surplus: surplus,
        actual: amount_paid,
        maximum: 0.57 * amount_billed,
        chunk: ic,
        qbo_line_item: qbo_line_item,
      }
    end
  end

  def accrual_date
    invoice_tracker.invoice_pass.start_of_month.end_of_month
  end

  def sync_qbo_bill!
    return unless contributor.qbo_vendor.present?

    bill = load_qbo_bill! || Quickbooks::Model::Bill.new
    bill.txn_date = invoice_tracker.invoice_pass.start_of_month.end_of_month
    bill.due_date = invoice_tracker.invoice_pass.start_of_month.end_of_month
    bill.doc_number = "Stacks_#{id}"

    bill.vendor_ref = Quickbooks::Model::BaseReference.new(contributor.qbo_vendor.id)

    line_item = Quickbooks::Model::BillLineItem.new(
      description: "https://stacks.garden3d.net/admin/invoice_trackers/#{invoice_tracker.id}/contributor_payouts/#{id}",
      amount: amount,
    )

    line_item.account_based_expense_item! do |detail|
      detail.account_ref = Quickbooks::Model::BaseReference.new(find_qbo_account!.id)
      # Optionally mark as billable to a customer
      # detail.customer_ref = Quickbooks::Model::BaseReference.new(customer_id)
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

  def toggle_acceptance!
    if accepted?
      raise "Cannot unaccept a payout if all payouts have been accepted." if invoice_tracker.contributor_payouts_status == :all_accepted
      update!(accepted_at: nil)
    else
      update!(accepted_at: DateTime.now)
    end
  end

  def accepted?
    accepted_at.present?
  end

  def payable?
    accepted? &&
    (invoice_tracker.status == :paid || (invoice_tracker.allow_early_contributor_payouts_on.present? && invoice_tracker.allow_early_contributor_payouts_on <= Date.today)) &&
    (invoice_tracker.contributor_payouts_status == :all_accepted)
  end

  def only_after_new_deal
    if invoice_tracker.invoice_pass.start_of_month < Stacks::System.singleton_class::NEW_DEAL_START_AT
      errors.add(:base, "Contributor Payouts can only be created for invoices sent after the New Deal began.")
    end
  end

  def status
    if deleted_at.present?
      "deleted"
    elsif blueprint.empty?
      "manual"
    else
      "calculated"
    end
  end

  def in_sync?
    begin
      blueprint_amount = (blueprint || {}).reduce(0) do |acc, (k, v)|
        acc += v.sum{|vv| vv["amount"].to_f}
        acc
      end
      blueprint_amount == amount
    rescue
      false
    end
  end

  def contributor_payouts_within_seventy_percent
    return if changes.keys == ["accepted_at"] # Don't check if the payout is being accepted or unaccepted

    cps = invoice_tracker.contributor_payouts.include?(self) ? invoice_tracker.contributor_payouts : [*invoice_tracker.contributor_payouts, self]

    if invoice_tracker.forecast_client.is_internal?
      max_amount = invoice_tracker.total
    else
      max_amount = invoice_tracker.total * (1 - invoice_tracker.company_treasury_split)
    end

    if cps.sum(&:amount) > (max_amount + 1) # Add a dollar to account for rounding errors
      errors.add(:base, "Contributor Payouts may not exceed #{ActionController::Base.helpers.number_to_currency(max_amount)} (#{100 * (1 - invoice_tracker.company_treasury_split)}% of invoice total).")
    end
  end

  def as_account_lead
    return 0 unless blueprint["AccountLead"].present?
    blueprint["AccountLead"].sum{|l| l["amount"]}
  end

  def as_team_lead
    return 0 unless blueprint["TeamLead"].present?
    blueprint["TeamLead"].sum{|l| l["amount"]}
  end

  def as_individual_contributor
    return 0 unless blueprint["IndividualContributor"].present?
    blueprint["IndividualContributor"].sum{|l| l["amount"]}
  end
end