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

  def is_time_off?
    name == "Time Off" && forecast_client.nil?
  end

  def is_internal?
    is_time_off? || forecast_client && forecast_client.is_internal?
  end

  def display_name
    "[#{data['code'] || 'Missing Forecast Project Code'}] #{data['name']}"
  end

  def edit_link
    "https://forecastapp.com/864444/projects/#{forecast_id}/edit"
  end

  def link
    date = Date.today.strftime('%Y-%m-%d')
    encoded = ERB::Util.url_encode("#{data['code']} #{data['name']}")
    "https://forecastapp.com/#{Stacks::Utils.config[:forecast][:account_id]}/schedule/projects?filter=#{encoded}&startDate=#{date}"
  end

  def has_multiple_hourly_rates?
    tags.filter { |t| t.ends_with?("p/h") }.length > 1
  end

  def has_no_explicit_hourly_rate?
    tags.filter { |t| t.ends_with?("p/h") }.length == 0
  end

  def hourly_rate
    hourly_rate_tags = tags.filter { |t| t.ends_with?("p/h") }
    if hourly_rate_tags.count == 0
      System.instance.default_hourly_rate
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
