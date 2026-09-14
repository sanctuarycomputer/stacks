module Mcp
  # Shared validation floor for write tools. Raises ArgumentError with a
  # caller-safe message (no internals) — tools rescue and return it verbatim.
  module WriteValidation
    ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/.freeze

    def self.integer!(name, value)
      # Integer(4.5) truncates rather than raising — a fractional id must
      # never silently mutate the neighboring entity
      raise ArgumentError, "#{name} must be an integer" if value.is_a?(Numeric) && value != value.to_i
      Integer(value)
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be an integer"
    end

    def self.short_string!(name, value, max)
      s = value.to_s
      raise ArgumentError, "#{name} must be #{max} characters or fewer" if s.length > max
      s
    end

    def self.date!(name, value)
      raise ArgumentError, "#{name} must be a YYYY-MM-DD date" unless value.to_s.match?(ISO_DATE)
      Date.parse(value.to_s)
    rescue Date::Error
      raise ArgumentError, "#{name} must be a valid YYYY-MM-DD date"
    end

    MAX_RANGE_DAYS = 366

    def self.date_range!(start_date, end_date)
      s = date!("start_date", start_date)
      e = date!("end_date", end_date)
      raise ArgumentError, "start_date must be on or before end_date" if s > e
      raise ArgumentError, "date range must be #{MAX_RANGE_DAYS} days or fewer" if (e - s).to_i > MAX_RANGE_DAYS
      [s, e]
    end

    def self.minutes!(value)
      m = integer!("minutes_per_day", value)
      raise ArgumentError, "minutes_per_day must be between 0 and 1440" unless (0..1440).cover?(m)
      m
    end
  end
end
