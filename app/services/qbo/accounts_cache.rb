module Qbo
  # In-memory cache of each QboAccount's chart of accounts for the duration of a
  # bill-sync session. Created once at the top of a sync run and threaded into
  # every Qbo::BillRouter so the chart is fetched once per enterprise, not once
  # per bill.
  class AccountsCache
    def initialize
      @by_account_id = {}
    end

    def accounts_for(qbo_account)
      @by_account_id[qbo_account.id] ||= qbo_account.fetch_all_accounts
    end
  end
end
