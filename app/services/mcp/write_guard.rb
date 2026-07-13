module Mcp
  # Runaway circuit breaker for the write surface — NOT a trust gate.
  # Caps mutations per calendar day so a stuck agent loop can't rewrite the
  # projection plane 10,000 times overnight. Deliberate slop: the counter is
  # a per-process MemoryStore (effective cap = DAILY_CAP × puma workers per
  # dyno), read-modify-write races undercount slightly, and LRU eviction can
  # reset it mid-day. All fine for a breaker; none of it is a guarantee.
  module WriteGuard
    DAILY_CAP = 500

    class CapExceeded < StandardError; end

    def self.check!
      # Rails 6.1 MemoryStore#increment returns nil for a missing key (and
      # has no initial: kwarg), so plain read-modify-write is the honest path.
      key = "mcp_write_count:#{Time.zone.today.iso8601}"
      count = (Rails.cache.read(key) || 0) + 1
      Rails.cache.write(key, count, expires_in: 48.hours)
      return count unless count > DAILY_CAP

      raise CapExceeded, "daily write cap (#{DAILY_CAP}) reached; refusing further mutations until tomorrow"
    end
  end
end
