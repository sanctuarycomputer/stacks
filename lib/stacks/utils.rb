class Stacks::Utils
  COLORS = [
    "#1F78FF",
    "#ffa500",
    "#7B4EFA",
    "#26bd50",
    "#FF6961",
    "#5C9DFF",
    "#FFBF47",
    "#55DD7B",
    "#A788FC",
    "#FF9E99",
    "#0052CC",
    "#B87700",
    "#1B883A",
    "#4406EF",
    "#FF160A",
  ]

  class << self
    def business_days_between(start_date, end_date)
      days_between = (end_date - start_date).to_i
      return 0 unless days_between > 0

      # Assuming we need to calculate days from 9th to 25th, 10-23 are covered
      # by whole weeks, and 24-25 are extra days.
      #
      # Su Mo Tu We Th Fr Sa    # Su Mo Tu We Th Fr Sa
      #        1  2  3  4  5    #        1  2  3  4  5
      #  6  7  8  9 10 11 12    #  6  7  8  9 ww ww ww
      # 13 14 15 16 17 18 19    # ww ww ww ww ww ww ww
      # 20 21 22 23 24 25 26    # ww ww ww ww ed ed 26
      # 27 28 29 30 31          # 27 28 29 30 31
      whole_weeks, extra_days = days_between.divmod(7)

      unless extra_days.zero?
        # Extra days start from the week day next to start_day,
        # and end on end_date's week date. The position of the
        # start date in a week can be either before (the left calendar)
        # or after (the right one) the end date.
        #
        # Su Mo Tu We Th Fr Sa    # Su Mo Tu We Th Fr Sa
        #        1  2  3  4  5    #        1  2  3  4  5
        #  6  7  8  9 10 11 12    #  6  7  8  9 10 11 12
        # ## ## ## ## 17 18 19    # 13 14 15 16 ## ## ##
        # 20 21 22 23 24 25 26    # ## 21 22 23 24 25 26
        # 27 28 29 30 31          # 27 28 29 30 31
        #
        # If some of the extra_days fall on a weekend, they need to be subtracted.
        # In the first case only corner days can be days off,
        # and in the second case there are indeed two such days.
        extra_days -= if start_date.tomorrow.wday <= end_date.wday
                        [start_date.tomorrow.sunday?, end_date.saturday?].count(true)
                      else
                        2
                      end
      end

      (whole_weeks * 5) + extra_days
    end

    def config
      Rails.application.credentials[:"#{ENV["BASE_HOST"] || "localhost:3000"}"]
    end

    def studios_for_email(email)
      fp = ForecastPerson.find_by(email: email)
      return [] if fp.nil?
      Studio.all.select{|s| (fp.roles).include?(s[:name])} || []
    end

    def hash_diff(a, b)
      a
        .reject { |k, v| b[k] == v }
        .merge!(b.reject { |k, _v| a.key?(k) })
    end

    def clamp(x, in_min, in_max, out_min, out_max)
      (x - in_min) * (out_max - out_min) / (in_max - in_min) + out_min;
    end

    def full_months_between(date2, date1)
      (date2.year - date1.year) * 12 + date2.month - date1.month - (date2.day >= date1.day ? 0 : 1)
    end
  end
end
