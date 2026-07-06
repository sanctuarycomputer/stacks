class Reimbursement < ApplicationRecord
  acts_as_paranoid
  include LedgerItem
  include BustsTaskCache
  include SyncsAsQboBill

  # Mirror the destroy chain on every other SyncsAsQboBill host (ContributorPayout,
  # ContributorAdjustment, ProfitShare, PayStub): when a Reimbursement is
  # destroyed, clear its qbo_bill_id and tear down the QBO bill so the
  # upstream vendor AP doesn't keep an orphaned payable.
  before_destroy :detach_and_destroy_qbo_bill

  belongs_to :accepted_by, class_name: 'AdminUser', optional: true

  scope :accepted, -> {
    where.not(accepted_by: nil)
  }

  scope :pending, -> {
    where.not(id: accepted)
  }

  def name
    display_name
  end

  def external_link
    "/admin/contributors/#{contributor.id}/reimbursements/#{id}"
  end

  def display_name
    "#{contributor.forecast_person.email} - #{created_at.strftime("%B %d, %Y")}: #{description}"
  end

  def accepted?
    accepted_by.present?
  end

  def payable?
    accepted?
  end

  # SyncsAsQboBill contract
  def bill_txn_date
    accepted_at&.to_date || created_at.to_date
  end

  def bill_description
    "https://stacks.garden3d.net/admin/ledgers/#{ledger_id}/reimbursements/#{id}"
  end

  def bill_doc_number_code
    "RB"
  end

  def effective_on_for_display
    created_at.to_date
  end
end
