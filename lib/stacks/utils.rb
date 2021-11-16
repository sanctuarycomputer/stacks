class Stacks::Utils
  class << self
    def config
      Rails.application.credentials[:"#{ENV["BASE_HOST"] || "localhost:3000"}"]
    end

    def clamp(x, in_min, in_max, out_min, out_max)
      (x - in_min) * (out_max - out_min) / (in_max - in_min) + out_min;
    end

    def full_months_between(date2, date1)
      (date2.year - date1.year) * 12 + date2.month - date1.month - (date2.day >= date1.day ? 0 : 1)
    end
  end
end
