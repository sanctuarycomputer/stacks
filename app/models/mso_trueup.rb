# An MSO executive's true-up for one month, on their garden3d ledger: what
# their tier entitles them to, less what they already earned that month
# across all their ledgers. To a monthly PeriodicReport what a ProfitShare is
# to a quarterly one; written by PeriodicReport#sync_mso_trueups!. Its
# `blueprint` is that executive's line of the computation.
#
# Dated the LAST DAY OF THE FEE MONTH, whenever it is synced or billed: that
# is the month it counts in as income, and the date on its QuickBooks bill.
#
# Only the executive it belongs to can accept it (AdminAuthorization).
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

  class Locked < StandardError; end

  belongs_to :periodic_report

  # A true-up under one cent has no row at all.
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

  # The report's month, NOT created_at and NOT the day it was synced or
  # billed: August's true-up, synced in October, is August's income.
  def payment_date
    periodic_report.period.ends_at
  end

  def effective_on_for_display
    payment_date
  end

  # As a profit share's, and one thing more: executives are paid only from a
  # fee that has been collected. Stored data only; no QuickBooks call.
  def payable?
    periodic_report.all_mso_trueups_accepted? && periodic_report.management_fee_collected?
  end

  def accepted?
    accepted_at.present?
  end

  # The vendor its bill is written to, in garden3d's QuickBooks.
  def qbo_vendor
    contributor.qbo_vendor_for(qbo_account_for_bill)
  end

  # Everything standing between this true-up and a bill, for the pages.
  def not_ready_to_pay_reasons
    reasons = []
    reasons << "Everyone on the team has to accept their true-up for the month." unless periodic_report.all_mso_trueups_accepted?
    reasons << "garden3d's management fee invoices for the month have to be paid." unless periodic_report.management_fee_collected?
    reasons << "The contributor needs a vendor in garden3d's QuickBooks." if qbo_account_for_bill && qbo_vendor.nil?
    reasons
  end

  # Accepted, and the month has a QuickBooks bill (this true-up's or another
  # executive's): an amount is in QuickBooks, so the month stays settled.
  # Un-accepting would let the next sync rewrite a billed amount.
  def locked?
    accepted? && periodic_report.mso_trueups.where.not(qbo_bill_id: nil).exists?
  end

  def toggle_acceptance!
    if locked?
      raise Locked, "A true-up for this month has a QuickBooks bill, so it can no longer be un-accepted."
    end

    update!(accepted_at: accepted? ? nil : DateTime.now)
  end

  # SyncsAsQboBill#sync_qbo_bill! has no guard of its own and returns nil
  # without a word when the contributor has no vendor. The nightly
  # stacks:sync_contributor_qbo_bills task calls this for payable true-ups only,
  # as the Money page does; this refuses anything not payable all the same.
  def sync_qbo_bill!(accounts_cache: nil)
    accounts_cache ||= Qbo::AccountsCache.new

    unless payable?
      raise NotPayable, "MsoTrueup #{id} is not payable yet: everyone on the team has to accept their true-up for " \
                        "the month, and the month's management fee has to be collected. No bill was written."
    end

    qbo_account = qbo_account_for_bill
    if qbo_account && contributor.qbo_vendor_for(qbo_account).nil?
      raise MissingVendor, "Contributor #{contributor.id} has no vendor in #{enterprise.name}'s QuickBooks. " \
                           "Create the vendor there, map it on their Contributor record (Team → " \
                           "Contributors → Edit), then sync again. No bill was written."
    end

    if qbo_account
      # Only the router's own "no such account"; anything else it raises
      # keeps its own message.
      begin
        Qbo::BillRouter.new(self, accounts_cache: accounts_cache).lines
      rescue Qbo::BillRouter::UnmappedAccount => e
        raise AccountNotConfigured, "#{enterprise.name} has no MSO compensation account that Stacks can post " \
                                    "to (concept mso_compensation). Finance checks the account exists in " \
                                    "QuickBooks with the number set in app/services/qbo/bill_router.rb. " \
                                    "No bill was written. (#{e.message})"
      end
    end

    super(accounts_cache: accounts_cache)
  end

  # SyncsAsQboBill contract. The bill's txn_date and due_date are both this:
  # the last day of the fee month, so the expense lands in its own month.
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
    return if ledger.nil? || ledger.enterprise_id == Enterprise.garden3d.id

    errors.add(:ledger, "must be a #{Enterprise::GARDEN3D_NAME} ledger")
  end
end
