module Mcp
  # Runaway circuit breaker for the write surface — NOT a trust gate.
  # Caps total mutations per calendar day so a stuck agent loop can't
  # rewrite the projection plane 10,000 times overnight.
  module WriteGuard
    DAILY_CAP = 500

    class CapExceeded < StandardError; end

    def self.check!
      key = "mcp_write_count:#{Date.today.iso8601}"
      count = Rails.cache.increment(key, 1, initial: 1, expires_in: 48.hours)
      # increment can return nil on some cache stores when the key is fresh —
      # fall back to a read-modify-write
      if count.nil?
        count = (Rails.cache.read(key) || 0) + 1
        Rails.cache.write(key, count, expires_in: 48.hours)
      end
      return count unless count > DAILY_CAP

      raise CapExceeded, "daily write cap (#{DAILY_CAP}) reached; refusing further mutations until tomorrow"
    end
  end
end
