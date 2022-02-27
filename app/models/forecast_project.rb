class ForecastProject < ApplicationRecord
  self.primary_key = "forecast_id"
  belongs_to :forecast_client, class_name: "ForecastClient", foreign_key: "client_id"
  has_many :forecast_assignments, class_name: "ForecastAssignment", foreign_key: "project_id"

  scope :archived, -> {
    where('data @> ?', {archived: true}.to_json)
  }

  scope :active, -> {
    where.not('data @> ?', {archived: true}.to_json)
  }

  def display_name
    "[#{data['code']}] #{data['name']}"
  end

  def link
    date = Date.today.strftime('%Y-%m-%d')
    encoded = ERB::Util.url_encode("#{data['code']} #{data['name']}")
    "https://forecastapp.com/#{Stacks::Utils.config[:forecast][:account_id]}/schedule/projects?filter=#{encoded}&startDate=#{date}"
  end

  def hourly_rate
    hourly_rate_tags = tags.filter { |t| t.ends_with?("p/h") }
    if hourly_rate_tags.count == 0
      Stacks::Utilization::DEFAULT_HOURLY_RATE
    else
      hourly_rate_tags.first.to_f
    end
  end

  def total_hours
    forecast_assignments.reduce(0) do |acc, a|
      acc += a.allocation_in_hours
    end
  end

  def total_value_during_range(start_of_range, end_of_range)
    forecast_assignments.reduce(0) do |acc, a|
      acc += a.value_during_range_in_usd(start_of_range, end_of_range)
    end
  end

  def total_hours_during_range(start_of_range, end_of_range)
    forecast_assignments.reduce(0) do |acc, a|
      acc += a.allocation_during_range_in_hours(start_of_range, end_of_range)
    end
  end
end
