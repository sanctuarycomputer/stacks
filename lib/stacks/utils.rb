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
