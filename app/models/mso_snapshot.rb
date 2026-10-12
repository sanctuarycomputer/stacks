# The record of one run of a month's MSO compensation: every input
# Mso::MonthlyRun read and every figure it produced. Mso::Benchmark is a live
# calculation that changes when the roster or a payout is edited later, so
# this row, not a recomputation, is what a past month was paid on.
#
# A re-run never edits a snapshot. It writes a new one and stamps the old one
# superseded. The figures below are immutable; only the stamps change:
#
#   superseded_at / superseded_by_id     a later run replaced this one
#   fee_collected_at                     an admin's run or Check collection
#                                        confirmed, with QuickBooks, that the
#                                        month's fee was paid. Withdrawn when
#                                        the pass's invoices change.
#   invalidated_at / invalidated_reason  something happened after the run
#                                        that means its figures may be wrong.
#                                        Nothing from it is payable, and only
#                                        a successful run (a new snapshot)
#                                        undoes that.
#
# Executive compensation: admins only (AdminAuthorization).
class MsoSnapshot < ApplicationRecord
  # Superseded or invalidated: not something to confirm collection on.
  class Unusable < StandardError; end

  FIGURES = %w[
    invoice_pass_id sanctuary_invoice_pass_id fee_income benchmark_average configured_n counted
    small_sample cap_percentage cap total_calculated total_trueup total_trueup_as_billed
    benchmark_members excluded_without_login lines drift reconciliation
  ].freeze

  ZERO = BigDecimal("0")

  belongs_to :invoice_pass
  belongs_to :sanctuary_invoice_pass, class_name: "InvoicePass"
  belongs_to :created_by, class_name: "AdminUser", optional: true
  belongs_to :superseded_by, class_name: "MsoSnapshot", optional: true
  has_many :mso_trueups

  scope :current, -> { where(superseded_at: nil) }

  validate :figures_never_change, on: :update

  # Withdraws "the fee was collected" from a pass's current snapshot. Called
  # when the pass's invoices change (one attached or detached, or refreshed
  # from QuickBooks): the confirmation described the invoices as they were.
  def self.unconfirm_collection!(invoice_pass_id)
    return 0 unless MsoTrueup.schema_ready?
    current.where(invoice_pass_id: invoice_pass_id).update_all(fee_collected_at: nil)
  end

  def current?
    superseded_at.nil?
  end

  def invalidated?
    invalidated_at.present?
  end

  def fee_collected?
    fee_collected_at.present?
  end

  def month
    invoice_pass.start_of_month
  end

  # ActiveAdmin's page title and breadcrumb.
  def display_name
    "MSO compensation, #{invoice_pass.invoice_month}#{current? ? '' : ' (superseded)'}"
  end

  # What is owed after this run, counting a billed true-up at its billed
  # amount, is more than the cap. Possible only when the fee fell after a
  # bill was written. The snapshot page warns about it.
  def over_cap?
    total_trueup_as_billed > cap
  end

  # The garden3d ledgers that are owed a true-up by this run. A line whose
  # true-up is zero has no row and needs no acceptance.
  def expected_ledger_ids
    lines.select { |line| BigDecimal(line["trueup"].to_s) > ZERO }.map { |line| line["ledger_id"] }
  end

  # One accepted true-up for EVERY line this run says is owed. Checking only
  # the rows that exist is unsafe: with two of three created and both
  # accepted, "all of them" would be true and two people would be paid at
  # figures computed for three.
  def all_expected_trueups_accepted?
    by_ledger = mso_trueups.index_by(&:ledger_id)
    expected_ledger_ids.all? { |ledger_id| by_ledger[ledger_id]&.accepted? }
  end

  # Nothing from this snapshot is payable any more, and confirming collection
  # cannot bring it back. Only running the month again does: that writes a
  # new snapshot.
  def invalidate!(reason)
    update_columns(invalidated_at: Time.current, invalidated_reason: reason.to_s.truncate(2000),
                   fee_collected_at: nil)
  end

  # Asks QuickBooks whether the month's management fee has been paid, and
  # stamps the answer. ONE QuickBooks read per fee invoice: call it from an
  # admin's click, never per row. Raises if any invoice cannot be read.
  def check_collection!
    raise Unusable, "This snapshot has been superseded; check collection on the current one" unless current?
    if invalidated?
      raise Unusable, "This run's figures are no longer valid (#{invalidated_reason}). Run the month again " \
                      "before confirming collection"
    end

    collected = Mso::ManagementFeeInvoices.collected?(invoice_pass: invoice_pass)
    update_columns(fee_collected_at: collected ? Time.current : nil)
    collected
  end

  private

  def figures_never_change
    touched = changed & FIGURES
    return if touched.empty?
    errors.add(:base, "A snapshot's figures cannot be changed (#{touched.join(', ')}); run the month again")
  end
end
