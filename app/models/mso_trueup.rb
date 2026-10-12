# An MSO executive's true-up for one month, on their garden3d ledger: what
# their tier entitles them to, less what they already earned that month
# across all their ledgers. Written and rewritten only by Mso::MonthlyRun.
# The figures behind the amount live on its MsoSnapshot.
#
# Dated the LAST DAY OF THE FEE MONTH, whenever it is run or billed: that is
# the month it counts in as income, and the date on its QuickBooks bill.
#
# Executive compensation: visible to admins and to the executive it belongs
# to. Only that executive can accept it (AdminAuthorization).
class MsoTrueup < ApplicationRecord
  acts_as_paranoid
  include LedgerItem
  include SyncsAsQboBill

  # Why a true-up was not sent to QuickBooks. Every message says what to do;
  # the Money page shows it to the admin who clicked.
  class SyncRefused < StandardError; end
  class NotPayable < SyncRefused; end
  class MissingVendor < SyncRefused; end
  class AccountNotConfigured < SyncRefused; end
  class NotCollected < SyncRefused; end
  class FiguresChanged < SyncRefused; end
  class BooksClosed < SyncRefused; end

  class Locked < StandardError; end
  class AmountChanged < StandardError; end

  belongs_to :invoice_pass
  belongs_to :mso_snapshot
  belongs_to :mso_role_period

  # A true-up under one cent has no row at all (see MsoSnapshot#expected_ledger_ids).
  validates :amount, numericality: { greater_than: 0 }
  validates :description, presence: true
  validate :lives_on_garden3d

  # As ProfitShare and PayStub: without this a deleted row orphans its bill.
  before_destroy :detach_and_destroy_qbo_bill

  # Migrations are run by hand on production, after the deploy. Everything
  # that enumerates ledger items asks this first, so the ledger, the Money
  # page and the nightly jobs keep working until the table exists.
  #
  # "Yes" is remembered for the life of the process. While the answer is
  # "no" the database is asked at most once a minute, so a ledger page before
  # the migration does not pay a query per balance, and nothing needs
  # restarting after it.
  def self.schema_ready?
    return true if @schema_ready

    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return false if @schema_checked_at && now - @schema_checked_at < 60

    @schema_checked_at = now
    @schema_ready = connection.data_source_exists?(table_name)
  end

  def payment_date
    invoice_pass.start_of_month.end_of_month
  end

  # Must be the pass month, NOT created_at and NOT the day it was run or
  # billed: August's true-up, run in October, is August's income. A re-run in
  # a later month would otherwise move this row into that month, where it
  # would count as that month's earned income.
  def effective_on_for_display
    payment_date
  end

  def accepted?
    accepted_at.present?
  end

  # Once a QuickBooks bill exists the amount may already have been paid.
  # Mso::MonthlyRun never changes or deletes a locked true-up, and it cannot
  # be un-accepted.
  def locked?
    qbo_bill_id.present?
  end

  # `expected_amount` is the amount the person was looking at when they
  # clicked. A run may have changed it since; accepting a figure nobody saw
  # is refused. Under the row lock Mso::MonthlyRun also takes.
  def toggle_acceptance!(expected_amount: nil)
    with_lock do
      if locked?
        raise Locked, "This true-up has a QuickBooks bill and can no longer be changed here. " \
                      "An admin must remove the bill first."
      end
      unless expected_amount.nil?
        seen = BigDecimal(expected_amount.to_s, exception: false)
        if seen != amount
          raise AmountChanged, "This true-up is now #{amount.to_s('F')}, not the figure you were shown. " \
                               "Look at it again before accepting."
        end
      end
      update!(accepted_at: accepted? ? nil : Time.current)
    end
  end

  # Reads stored data only: no QuickBooks call, and no read of the invoice
  # mirrors. This is called per row on ledger pages and the Money page.
  #
  # A true-up with a bill is payable, full stop: the money is in garden3d's
  # accounts payable whatever happens to the snapshot afterwards, and a row
  # that stopped being payable could never settle here. Before the bill,
  # "the fee was collected" is a stamp on the snapshot, set from the
  # refreshing gate by Mso::MonthlyRun or an admin's Check collection click.
  def payable?
    return true if locked?
    return false unless accepted?

    snapshot = mso_snapshot
    snapshot.present? && snapshot.current? && !snapshot.invalidated? && snapshot.fee_collected? &&
      snapshot.all_expected_trueups_accepted?
  end

  # sync_qbo_bill! has no payable guard of its own, and the nightly
  # stacks:sync_contributor_qbo_bills task pushes every row it is given.
  # MsoTrueup is deliberately not in that task; this makes sure nothing
  # unaccepted or uncollected can reach QuickBooks even if it is added.
  # (Task 8 replaces this with the full set of checks.)
  def sync_qbo_bill!(accounts_cache: nil)
    unless payable?
      raise NotPayable, "MsoTrueup #{id} is not payable yet: it needs its executive's acceptance, every " \
                        "other executive's acceptance for the month, and a confirmed fee collection. " \
                        "No bill was written."
    end
    super
  end

  # SyncsAsQboBill contract. The bill's txn_date AND its due_date are both
  # this (syncs_as_qbo_bill.rb:145-146 sets them to the same value): the last
  # day of the fee month, so the expense lands in the month it belongs to.
  def bill_txn_date
    payment_date
  end

  def bill_description
    "https://stacks.garden3d.net/admin/ledgers/#{ledger_id}/mso_trueups/#{id}"
  end

  def bill_doc_number_code
    "MT"
  end

  private

  def lives_on_garden3d
    garden3d_id = Enterprise.garden3d.id
    if ledger && ledger.enterprise_id != garden3d_id
      errors.add(:ledger, "must be a #{Enterprise::GARDEN3D_NAME} ledger")
    end
    if invoice_pass && invoice_pass.enterprise_id != garden3d_id
      errors.add(:invoice_pass, "must be #{Enterprise::GARDEN3D_NAME}'s pass")
    end
  end
end
