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
  # The true-up had a bill and QuickBooks no longer has it.
  class BillGone < SyncRefused; end
  # The true-up has a bill and QuickBooks did not hand it over at the write.
  class BillUnreadable < SyncRefused; end

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

  # Creating the bill is what locks this true-up's amount, so the last checks
  # happen here. sync_qbo_bill! itself has no guard of any kind, returns nil
  # without a word when the contributor has no vendor, and is called for every
  # row by the nightly stacks:sync_contributor_qbo_bills task. MsoTrueup is
  # deliberately not in that task; this makes sure nothing wrong can reach
  # QuickBooks even if it is ever added.
  #
  # For the FIRST bill this makes QuickBooks reads (the chart of accounts and
  # one per management fee invoice) and one full computation of the month.
  # It is an admin's click on the Money page.
  #
  # A bill is CREATED only straight from the first-bill checks, in the same
  # call. A true-up that already had a bill never gets another one here: if
  # QuickBooks no longer has it (someone deleted it there), the row is
  # unlocked exactly as the nightly refresh would unlock it and the sync is
  # refused; the month has to be run again before anything is billed.
  def sync_qbo_bill!(accounts_cache: nil)
    accounts_cache ||= Qbo::AccountsCache.new

    # Outside the lock and its transaction: a stamp these checks withdraw
    # must stay withdrawn when the sync is then refused.
    assert_can_be_billed!(accounts_cache)
    if locked?
      first_bill_checked = false
      assert_bill_still_exists!
    else
      assert_first_bill_is_still_right!
      first_bill_checked = true
    end

    # The row lock makes a double click safe: the second caller waits here,
    # reloads, finds the bill the first one created and updates it instead
    # of creating another. Mso::MonthlyRun takes the same lock.
    with_lock do
      raise NotPayable, not_payable_message unless payable?

      begin
        # Read by load_qbo_bill! below, which is where the concern decides
        # between updating a bill and creating one.
        @bill_sync = { first_bill_checked: first_bill_checked }
        super(accounts_cache: accounts_cache)
      rescue Quickbooks::IntuitRequestException => e
        # The bill is dated the last day of the fee month. Once that month is
        # closed in QuickBooks a bill dated in it is rejected. Recognised by
        # the wording of QuickBooks' message; anything else is passed on.
        raise unless e.message.to_s.match?(/period has closed|books (are|is) closed|closing date/i)

        raise BooksClosed, "#{enterprise.name}'s books are closed for #{bill_txn_date.strftime('%m/%d/%Y')}, " \
                           "the date this bill must carry. Finance has to reopen the period (or move the " \
                           "closing date) in QuickBooks; then sync again. MSO bills need creating before " \
                           "the month is closed. No bill was written. (QuickBooks said: #{e.message})"
      ensure
        @bill_sync = nil
      end
    end
  end

  # SyncsAsQboBill#sync_qbo_bill! does `load_qbo_bill! || a new bill`, and
  # load_qbo_bill! answers nil three ways: the row has no bill; the bill is
  # gone from QuickBooks (it also clears the row's bill id); or QuickBooks
  # could not be read at all. Inside a sync, only the first may go on to
  # create a bill, and only when this same call passed the first-bill checks.
  # Outside a sync (removing a bill) it behaves as the concern's does.
  def load_qbo_bill!
    sync = @bill_sync
    return super if sync.nil?

    had_bill = qbo_bill_id.present?
    bill_id = qbo_bill_id
    remote = super
    return remote unless remote.nil?
    return nil if !had_bill && sync[:first_bill_checked]

    if had_bill
      raise BillUnreadable, "QuickBooks bill #{bill_id} for MsoTrueup #{id} could not be read just now, or has " \
                            "just been deleted there. No bill was written. Sync again in a moment."
    end
    raise SyncRefused, "MsoTrueup #{id} has no QuickBooks bill and was not checked for a first one in this " \
                       "sync. No bill was written. Sync again."
  end

  # An admin's way to unfreeze a true-up whose figure needs to change. Reads
  # the bill from QuickBooks, refuses if it has any payment
  # (SyncsAsQboBill::PaidQboBillError), deletes it. The acceptance is cleared
  # and the snapshot invalidated, so the row cannot be synced again at the old
  # amount: the month has to be run again first.
  def remove_qbo_bill!
    detach_and_destroy_qbo_bill
    update_columns(accepted_at: nil)
    mso_snapshot.invalidate!("The QuickBooks bill for MsoTrueup #{id} was removed. Run the month again.")
  end

  # READ ONLY. Brings the stored copy of this true-up's bill up to date so a
  # bill paid in QuickBooks is seen as paid here. The nightly bill sync does
  # this for other ledger items by re-writing each bill; this only reads.
  # It can never create or change a bill.
  def refresh_qbo_bill_mirror!
    return :no_bill unless locked?

    qbo_account = qbo_account_for_bill
    return :no_account if qbo_account.nil?

    begin
      remote = qbo_account.fetch_bill_by_id(qbo_bill_id)
    rescue => e
      raise unless e.message.to_s.start_with?("Object Not Found:")

      # Someone deleted the bill in QuickBooks. delete_all, not destroy:
      # QboBill#destroy would call QuickBooks to delete it again.
      QboBill.where(qbo_account_id: qbo_account.id, qbo_id: qbo_bill_id).delete_all
      gone = qbo_bill_id
      update_columns(qbo_bill_id: nil, accepted_at: nil)
      mso_snapshot.invalidate!("QuickBooks bill #{gone} for MsoTrueup #{id} no longer exists. Run the month again.")
      return :bill_gone
    end

    # By the (account, id) pair: a bill id is unique only within one account.
    mirrors = QboBill.where(qbo_account_id: qbo_account.id, qbo_id: qbo_bill_id)
    if mirrors.exists?
      # update_all: no callbacks. (qbo_bills has no timestamp columns.)
      mirrors.update_all(data: remote.as_json)
    else
      QboBill.create!(qbo_id: qbo_bill_id, qbo_account_id: qbo_account.id, data: remote.as_json,
                      qbo_vendor_id: remote.vendor_ref&.value)
    end
    :refreshed
  end

  # How long a settled bill is still re-read each night
  # (.refresh_bill_mirrors!), counted from the true-up's own month.
  PAID_MIRROR_REFRESH_MONTHS = 6

  # Nightly, from garden3d's daily step. QuickBooks READS only. One failure
  # does not stop the rest.
  #
  # A settled bill is still read while its month is within the last
  # PAID_MIRROR_REFRESH_MONTHS months: a payment can be voided after the
  # fact, and a mirror never read again would go on saying "paid". Older
  # settled bills are skipped, which is what bounds the reads.
  def self.refresh_bill_mirrors!(today: Date.today)
    return [] unless schema_ready?

    recent = today.beginning_of_month - PAID_MIRROR_REFRESH_MONTHS.months
    failures = []
    where.not(qbo_bill_id: nil).includes(:invoice_pass).find_each do |trueup|
      next if trueup.invoice_pass.start_of_month < recent && trueup.qbo_bill&.paid?

      trueup.refresh_qbo_bill_mirror!
    rescue => e
      failures << [trueup.id, "#{e.class}: #{e.message}"]
      Rails.logger.error("[mso] bill mirror refresh failed for MsoTrueup #{trueup.id}: #{e.class}: #{e.message}")
    end
    failures
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

  def not_payable_message
    "MsoTrueup #{id} is not payable yet: it needs its executive's acceptance, every other executive's " \
      "acceptance for the month, and a confirmed fee collection. No bill was written."
  end

  def assert_can_be_billed!(accounts_cache)
    raise NotPayable, not_payable_message unless payable?

    qbo_account = qbo_account_for_bill
    if qbo_account.nil?
      raise SyncRefused, "#{enterprise.name} has no connected QuickBooks account. No bill was written."
    end
    if contributor.qbo_vendor_for(qbo_account).nil?
      raise MissingVendor, "Contributor #{contributor.id} has no vendor in #{enterprise.name}'s QuickBooks. " \
                           "Create the vendor there, map it on their Contributor record (Team → " \
                           "Contributors → Edit), then sync again. No bill was written."
    end

    # Only the router's own "no such account". Anything else it raises (the
    # chart of accounts could not be read, the enterprise is not registered)
    # is a different problem and keeps its own message.
    begin
      Qbo::BillRouter.new(self, accounts_cache: accounts_cache).lines
    rescue Qbo::BillRouter::UnmappedAccount => e
      raise AccountNotConfigured, "#{enterprise.name} has no MSO compensation account that Stacks can " \
                                  "post to (concept mso_compensation). Finance creates the account in " \
                                  "QuickBooks; its account number then replaces the placeholder in " \
                                  "app/services/qbo/bill_router.rb. No bill was written. (#{e.message})"
    end
  end

  # For a true-up that already has a bill: ONE QuickBooks read. If the bill
  # is gone, refresh_qbo_bill_mirror! has already cleared the bill id and the
  # acceptance and invalidated the snapshot (outside any transaction here, so
  # it stays done). Any other QuickBooks failure is passed on as it is.
  def assert_bill_still_exists!
    bill_id = qbo_bill_id
    return unless refresh_qbo_bill_mirror! == :bill_gone

    raise BillGone, "QuickBooks bill #{bill_id} for MsoTrueup #{id} no longer exists: someone deleted it in " \
                    "QuickBooks. This true-up is no longer billed or accepted and the month's run is marked " \
                    "invalid. Run the month again; it will then need accepting again. No bill was written."
  end

  # Only before the FIRST bill. Afterwards the amount is in QuickBooks and
  # these questions are the snapshot's drift, not a reason to refuse an update.
  def assert_first_bill_is_still_right!
    collected =
      begin
        mso_snapshot.check_collection!
      rescue Mso::IntercompanyInvoices::Error, MsoSnapshot::Unusable => e
        raise NotCollected, "#{e.message}. No bill was written."
      end
    unless collected
      raise NotCollected, "The management fee for #{payment_date.strftime('%B %Y')} has not been collected " \
                          "in full, as of a check with QuickBooks just now. No bill was written."
    end

    fresh =
      begin
        Mso::MonthlyRun.preview(invoice_pass: invoice_pass).fetch(ledger_id, BigDecimal("0"))
      rescue Mso::MonthlyRun::Refused => e
        raise FiguresChanged, "The month can no longer be computed as it was run (#{e.message}). " \
                              "Run the month again. No bill was written."
      end
    return if fresh == amount

    raise FiguresChanged, "This true-up is #{amount.to_s('F')} but a fresh computation gives " \
                          "#{fresh.to_s('F')}: figures changed since the run. Run the month again. " \
                          "No bill was written."
  end

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
