module QboTokens
  # Daily cron step 1: proactively refresh every enterprise's QBO OAuth token
  # so downstream tasks (sync_all!, generate_snapshot!, OpenScheduledCycles)
  # don't race the 10-minute staleness gate or surprise-401 mid-job.
  #
  # Per-enterprise failures are isolated, logged, and reported via Result
  # structs — the caller (the rake task) is expected to continue regardless.
  # If a refresh_token has been revoked on Intuit's side (invalid_grant), we
  # do NOT retry; manual reauth via the admin edit form is the only fix.
  class RefreshAll
    MAX_ATTEMPTS = 3

    Result = Struct.new(:qbo_account, :refreshed, :error, keyword_init: true) do
      def ok? = error.nil?
    end

    def self.call
      QboAccount.joins(:qbo_token).find_each.map { |qa| refresh_one(qa) }
    end

    def self.refresh_one(qbo_account)
      attempts = 0
      begin
        attempts += 1
        # Single-row UPDATE inside `make_and_refresh_qbo_access_token` is
        # already atomic; the transaction is here to honour the
        # "transaction per enterprise" requirement and to give a clean
        # rollback point if future code adds more writes alongside the
        # qbo_token update.
        ActiveRecord::Base.transaction do
          qbo_account.make_and_refresh_qbo_access_token(force: true)
        end
        Result.new(qbo_account: qbo_account, refreshed: true, error: nil)
      rescue => e
        if invalid_grant?(e)
          Rails.logger.error("[QboTokens::RefreshAll] enterprise=#{qbo_account.enterprise_id} refresh_token revoked (#{e.class}: #{e.message}). Manual reauth required.")
          Result.new(qbo_account: qbo_account, refreshed: false, error: e)
        elsif attempts < MAX_ATTEMPTS
          sleep_before_retry(attempts)
          retry
        else
          Rails.logger.error("[QboTokens::RefreshAll] enterprise=#{qbo_account.enterprise_id} #{e.class}: #{e.message} (gave up after #{attempts} attempts)")
          Result.new(qbo_account: qbo_account, refreshed: false, error: e)
        end
      end
    end

    # 1s, 2s, 4s — max total ~7s wall-clock before giving up on one enterprise.
    def self.sleep_before_retry(attempt)
      sleep(2 ** (attempt - 1))
    end

    # Intuit returns OAuth2::Error with body containing `invalid_grant` when
    # the refresh_token has been revoked or rotated out from under us. No
    # number of retries will fix this — it needs a manual reauth.
    def self.invalid_grant?(error)
      return false unless error.is_a?(OAuth2::Error)
      msg = error.message.to_s
      msg.include?("invalid_grant") || msg.include?("Token revoked") || msg.include?("Token expired")
    end
  end
end
