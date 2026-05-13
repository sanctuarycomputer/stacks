# TODO: Slowly deprecate this for qbo_account.rb now that we have
# enterprises with different QBO credentials.
#
# Phase D: All Stacks::Quickbooks.* class methods delegate to Sanctuary's
# qbo_account. Until Phase F migrates legacy callers (invoice_tracker,
# profit_share_pass, forecast_client, qbo_invoice, qbo_bill, dashboard,
# forecast_assignment, etc.) to use per-enterprise qbo_accounts directly,
# this delegation preserves backwards compatibility — every
# Stacks::Quickbooks caller transparently routes to Sanctuary's QboAccount.
#
# Note: callers that read Stacks::Utils.config[:quickbooks][:realm_id]
# or build their own QBO service objects (e.g. invoice_tracker.rb:594)
# are left untouched here and will be migrated in Phase F.

class Stacks::Quickbooks
  class << self
    # ---------------------------------------------------------------------------
    # Private helper — Sanctuary's QboAccount is the canonical delegatee for
    # every class-level method until Phase F.
    # ---------------------------------------------------------------------------
    def sanctuary_qbo_account
      Enterprise.sanctuary.qbo_account.tap do |qa|
        raise "Sanctuary enterprise has no qbo_account; configure it via the admin" if qa.nil?
      end
    end
    private :sanctuary_qbo_account

    # ---------------------------------------------------------------------------
    # Token management
    #
    # Delegates to Sanctuary's QboAccount, then mirrors the refreshed token
    # into the legacy QuickbooksToken table so any code still reading that
    # table continues to see a current token. Deprecate the mirror once all
    # such callers are removed (Phase F+).
    # ---------------------------------------------------------------------------
    def make_and_refresh_qbo_access_token(force_refresh = false)
      access_token = sanctuary_qbo_account.make_and_refresh_qbo_access_token
      return access_token if access_token.nil?

      # Mirror to legacy QuickbooksToken so legacy reads stay in sync.
      sanctuary_qbo_token = sanctuary_qbo_account.qbo_token
      return access_token if sanctuary_qbo_token.nil?

      legacy = QuickbooksToken.order(:created_at).last
      if legacy.nil?
        QuickbooksToken.create!(
          token: sanctuary_qbo_token.token,
          refresh_token: sanctuary_qbo_token.refresh_token,
        )
      elsif legacy.token != sanctuary_qbo_token.token || legacy.refresh_token != sanctuary_qbo_token.refresh_token
        legacy.update!(
          token: sanctuary_qbo_token.token,
          refresh_token: sanctuary_qbo_token.refresh_token,
        )
      end

      access_token
    end

    # ---------------------------------------------------------------------------
    # Fetch helpers — thin delegation
    # ---------------------------------------------------------------------------

    def fetch_all_accounts
      sanctuary_qbo_account.fetch_all_accounts
    end

    def fetch_all_vendors
      sanctuary_qbo_account.fetch_all_vendors
    end

    def fetch_all_invoices
      sanctuary_qbo_account.fetch_all_invoices
    end

    def fetch_all_terms
      sanctuary_qbo_account.fetch_all_terms
    end

    def fetch_all_items
      sanctuary_qbo_account.fetch_all_items
    end

    def fetch_all_customers
      sanctuary_qbo_account.fetch_all_customers
    end

    def fetch_all_bills
      sanctuary_qbo_account.fetch_all_bills
    end

    def delete_bill(bill)
      sanctuary_qbo_account.delete_bill(bill)
    end

    def fetch_bill_by_id(id)
      sanctuary_qbo_account.fetch_bill_by_id(id)
    end

    def fetch_invoice_by_id(id)
      sanctuary_qbo_account.fetch_invoice_by_id(id)
    end

    def fetch_profit_and_loss_report_for_range(start_of_range, end_of_range, accounting_method = "Cash")
      sanctuary_qbo_account.fetch_profit_and_loss_report_for_range(start_of_range, end_of_range, accounting_method)
    end

    # ---------------------------------------------------------------------------
    # Sync helpers — delegate to QboAccount instance methods
    # ---------------------------------------------------------------------------

    def sync_all_invoices!
      sanctuary_qbo_account.sync_all_invoices!
    end

    def sync_all_vendors!
      sanctuary_qbo_account.sync_all_vendors!
    end

    def sync_all_bills!
      sanctuary_qbo_account.sync_all_bills!
    end

    def cleanup_orphaned_qbo_objects!
      sanctuary_qbo_account.cleanup_orphaned_qbo_objects!
    end

    # P&L report syncs: keep the legacy date range (2020-01-01) so callers
    # that depend on historical data aren't silently truncated. QboAccount's
    # instance methods start from started_at (2023-01-01) and are used when
    # syncing per-enterprise data. These module-level methods pass nil as the
    # qbo_account arg so QboProfitAndLossReport uses the legacy/global store.
    def sync_monthly_profit_and_loss_reports!
      time = Date.new(2020, 1, 1)
      while time < Date.today
        QboProfitAndLossReport.find_or_fetch_for_range(
          time.beginning_of_month,
          time.end_of_month,
          true,
          nil
        )
        time = time.advance(months: 1)
      end
    end

    def sync_quarterly_profit_and_loss_reports!
      time = Date.new(2020, 1, 1)
      while time < Date.today
        QboProfitAndLossReport.find_or_fetch_for_range(
          time.beginning_of_quarter,
          time.end_of_quarter,
          true,
          nil
        )
        time = time.advance(months: 3)
      end
    end

    def sync_yearly_profit_and_loss_reports!
      time = Date.new(2020, 1, 1)
      while time < Date.today
        QboProfitAndLossReport.find_or_fetch_for_range(
          time.beginning_of_year,
          time.end_of_year,
          true,
          nil
        )
        time = time.advance(years: 1)
      end
    end

    # ---------------------------------------------------------------------------
    # Top-level orchestrator
    # ---------------------------------------------------------------------------
    def sync_all!
      Retriable.retriable(tries: 5, base_interval: 1, multiplier: 2, max_interval: 10) do
        cleanup_orphaned_qbo_objects!
      end

      Retriable.retriable(tries: 5, base_interval: 1, multiplier: 2, max_interval: 10) do
        sync_monthly_profit_and_loss_reports!
      end

      Retriable.retriable(tries: 5, base_interval: 1, multiplier: 2, max_interval: 10) do
        sync_quarterly_profit_and_loss_reports!
      end

      Retriable.retriable(tries: 5, base_interval: 1, multiplier: 2, max_interval: 10) do
        sync_yearly_profit_and_loss_reports!
      end

      Retriable.retriable(tries: 5, base_interval: 1, multiplier: 2, max_interval: 10) do
        sync_all_invoices!
      end

      Retriable.retriable(tries: 5, base_interval: 1, multiplier: 2, max_interval: 10) do
        sync_all_vendors!
      end

      Retriable.retriable(tries: 5, base_interval: 1, multiplier: 2, max_interval: 10) do
        sync_all_bills!
      end
    end
  end
end
