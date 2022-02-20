class Stacks::Retention
  class << self
    def average_days_spent
      days_spent = (AdminUser.all.map do |a|
        a.full_time_periods.reduce(0) do |acc, ftp|
          acc + ((ftp.ended_at || Date.today) - ftp.started_at).to_i
        end
      end).select{|d| d > 0}
      days_spent.sum / days_spent.length
    end

    #def annual_turnover(year = 2021)
    #  AdminUser.terminated_during(year) / AdminUser.active_at_year_start(year)
    #end
  end
end
