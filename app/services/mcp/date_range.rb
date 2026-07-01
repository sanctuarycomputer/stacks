module Mcp
  # Builds an occurred_at Range from optional ISO8601 bounds passed by the agent.
  # One-sided bounds are fine (beginless/endless Range); invalid/blank input is ignored
  # rather than erroring the tool call.
  module DateRange
    def self.parse(occurred_after, occurred_before)
      after = time(occurred_after)
      before = time(occurred_before)
      return nil unless after || before

      (after..before)
    end

    def self.time(str)
      return nil if str.blank?

      Time.zone.parse(str.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
