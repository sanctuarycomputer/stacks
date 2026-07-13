module Mcp
  # Shared validation floor for write tools. Raises ArgumentError with a
  # caller-safe message (no internals) — tools rescue and return it verbatim.
  module WriteValidation
    ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/.freeze

    def self.integer!(name, value)
      Integer(value)
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be an integer id"
    end

    def self.date!(name, value)
      raise ArgumentError, "#{name} must be a YYYY-MM-DD date" unless value.to_s.match?(ISO_DATE)
      Date.parse(value.to_s)
    rescue Date::Error
      raise ArgumentError, "#{name} must be a valid YYYY-MM-DD date"
    end

    def self.date_range!(start_date, end_date)
      s = date!("start_date", start_date)
      e = date!("end_date", end_date)
      raise ArgumentError, "start_date must be on or before end_date" if s > e
      [s, e]
    end

    def self.minutes!(value)
      m = integer!("minutes_per_day", value)
      raise ArgumentError, "minutes_per_day must be between 0 and 1440" unless (0..1440).cover?(m)
      m
    end
  end
end
