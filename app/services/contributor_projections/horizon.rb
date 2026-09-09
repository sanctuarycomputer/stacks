module ContributorProjections
  # The months a projection covers: the current month plus MONTHS_AHEAD.
  # `months` are Stacks::Period instances for display; key hashes by
  # `month_keys` (each period's starts_at Date), never by the Period itself.
  Horizon = Struct.new(:starts_at, :ends_at, :months, keyword_init: true) do
    def self.current(today = Date.today)
      months = (0..MONTHS_AHEAD).map do |i|
        first = today.beginning_of_month + i.months
        Stacks::Period.new(first.strftime("%B, %Y"), first, first.end_of_month, :month)
      end
      new(starts_at: months.first.starts_at, ends_at: months.last.ends_at, months: months)
    end

    def month_keys
      months.map(&:starts_at)
    end
  end
end
