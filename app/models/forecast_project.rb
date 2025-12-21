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

  scope :with_archived_at_bottom , -> {
    order(Arel.sql("data->>'archived'").asc)
  }

  def hourly_rate_override_for_email_address(email)
    return nil unless notes.present?
    # It's possible to record overrides to a particular individual's
    # (or contractor's) hourly rates in Harvest Forecast by adding a note
    # to the Forecast project in the form:
    # "contractor-name@contractor-domain.com:150p/h"
    regexp = /^([^:]+):\$?([0-9\.]+)p\/h/
    matches = notes.scan(regexp)
    match = matches.find do |match|
      match[0].downcase == email.downcase
    end
    return match[1].to_f if match.present?
    nil
  end

  def self.candidates_for_association_with_project_tracker(project_tracker)
    forecast_codes_for_other_trackers = self.forecast_codes_already_associated_to_project_tracker(project_tracker.id)
    forecast_codes_for_this_tracker = project_tracker.forecast_projects.map(&:code)

    not_archived = with_archived_at_bottom.active
    archived = with_archived_at_bottom.archived

   [
      nil,
      *not_archived.select{|fp| fp.code.present?}.sort_by(&:code),
      nil,
      *not_archived.select{|fp| !fp.code.present?}.sort_by{|fp| fp.data.dig("name") },
      nil,
      *archived.sort_by.sort_by{|fp| fp.code || "" }
    ].map do |fp|
      next ["------------------", 0, {disabled: true}] if fp.nil?

      [
        fp.display_name,
        fp.id,
        {
          disabled: !(
            forecast_codes_for_other_trackers.exclude?(fp.code) ||
            forecast_codes_for_this_tracker.include?(fp.code)
          )
        }
      ]
    end
  end

  def self.forecast_codes_already_associated_to_project_tracker(except_project_tracker_id = nil)
    all_ptfps = ProjectTrackerForecastProject.includes(:forecast_project).all

    filtered_ptfps = all_ptfps.reject do |ptfp|
      ptfp.project_tracker_id == except_project_tracker_id
    end

    filtered_ptfps.map(&:forecast_project).compact.map(&:code).flatten
  end

  def forecast_assignments
    @_forecast_assignments ||= super.includes(:forecast_project)
  end

  def is_time_off?
    name == "Time Off" && forecast_client.nil?
  end

  def is_internal?
    is_time_off? || forecast_client&.is_internal?
  end

  def display_name
    title = "[#{data['code'] || code || '????'}] #{data['name'] || name || 'Untitled'}"
    title = "*ARCHIVED* #{title}" if data["archived"]
    title
  end

  def edit_link
    "https://forecastapp.com/864444/projects/#{forecast_id}/edit"
  end

  def external_link
    link
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
