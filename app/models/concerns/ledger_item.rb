# Shared interface for any model that affects a contributor's ledger
# (ContributorPayout, ContributorAdjustment, Trueup, Reimbursement,
# ProfitShare, DeelInvoiceAdjustment). Each host model has its own table
# and type-specific columns; this concern provides the common contract:
#
# - belongs_to :ledger (the per-(enterprise, contributor) anchor)
# - delegate :contributor, :enterprise to the ledger
# - default signed_amount = +amount (override for deductions)
# - default payable? = accepted_at.present? (override per host)
#
# Hosts MAY override signed_amount and payable? but should NOT override
# the ledger / contributor / enterprise interface.
module LedgerItem
  extend ActiveSupport::Concern

  included do
    belongs_to :ledger
    delegate :contributor, :enterprise, to: :ledger
  end

  def signed_amount
    amount
  end

  def payable?
    respond_to?(:accepted_at) && accepted_at.present?
  end
end
