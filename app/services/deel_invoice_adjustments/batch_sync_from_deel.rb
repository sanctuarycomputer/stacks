# Daily (or manual) sync of Deel GET /invoice-adjustments/:id into local `deel_status` / `synced_at`.
# Paces requests and retries on rate-limit / transient upstream errors only.
class DeelInvoiceAdjustments::BatchSyncFromDeel
  # Target ~1 req/s or slightly under to stay clear of vendor rate limits.
  PACE_SECONDS = 0.65
  MAX_ATTEMPTS_PER_ROW = 6

  def self.run!
    ok = 0
    removed = 0
    failed = []

    DeelInvoiceAdjustment.find_each do |adj|
      result = sync_one_with_retries!(adj)
      case result
      when :removed
        removed += 1
      else
        ok += 1
      end
      sleep(PACE_SECONDS)
    rescue Stacks::Deel::ApiError => e
      failed << {
        id: adj.id,
        deel_adjustment_id: adj.deel_adjustment_id,
        error: e.message,
      }
    end

    Rails.logger.info("[DeelInvoiceAdjustments::BatchSyncFromDeel] synced=#{ok} removed=#{removed} failed=#{failed.size}")
    failed.each { |f| Rails.logger.warn("[DeelInvoiceAdjustments::BatchSyncFromDeel] #{f.inspect}") }

    { synced: ok, removed: removed, failed: failed }
  end

  def self.sync_one_with_retries!(adj)
    attempts = 0
    loop do
      begin
        return DeelInvoiceAdjustments::SyncFromDeel.call(adj)
      rescue Stacks::Deel::ApiError => e
        attempts += 1
        raise e unless e.retryable_rate_limit?
        raise e if attempts >= MAX_ATTEMPTS_PER_ROW

        backoff = [2**attempts, 90].min
        Rails.logger.info("[DeelInvoiceAdjustments::BatchSyncFromDeel] retrying id=#{adj.id} http=#{e.http_code} in #{backoff}s (attempt #{attempts}/#{MAX_ATTEMPTS_PER_ROW})")
        sleep(backoff)
      end
    end
  end
end
