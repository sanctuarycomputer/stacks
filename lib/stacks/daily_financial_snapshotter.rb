class Stacks::DailyFinancialSnapshotter
  def self.snapshot_all!
    current_date = Stacks::System.singleton_class::UTILIZATION_START_AT
    end_date = Date.today
    studios = Studio.all

    while current_date <= end_date
      snapshotter = self.new(current_date, studios)
      snapshotter.snapshot!
      current_date += 1.day
    end
  end

  def initialize(effective_date = nil, studios = nil)
    @effective_date = effective_date || Date.today
    @studios = studios || Studio.all
  end

  def snapshot!
    Rails.logger.info(
      "Creating daily project financial snapshots for date #{@effective_date}..."
    )

    attributes = ForecastAssignment
      .where("start_date <= ? AND end_date >= ?", @effective_date, @effective_date)
      .includes(:forecast_person, :forecast_project)
      .map { |assignment| snapshot_attributes_for_assignment(assignment) }
      .compact

    ActiveRecord::Base.transaction do
      ForecastAssignmentDailyFinancialSnapshot
        .where(effective_date: @effective_date)
        .delete_all

      unless attributes.empty?
        ForecastAssignmentDailyFinancialSnapshot.insert_all!(attributes)
      end
    end
  end

  private

  def snapshot_attributes_for_assignment(forecast_assignment)
    hours = forecast_assignment.allocation_during_range_in_hours(
      @effective_date,
      @effective_date
    )

    return nil if hours == 0

    forecast_person = forecast_assignment.forecast_person
    forecast_project = forecast_assignment.forecast_project
    person_id = forecast_person.nil? ? 0 : forecast_person.id
    studio_id = forecast_person_studio_id(forecast_person)
    hourly_cost = forecast_person_hourly_cost(forecast_person, forecast_project)
    needs_review = needs_review?(forecast_person, studio_id, hourly_cost)

    {
      forecast_assignment_id: forecast_assignment.id,
      forecast_person_id: person_id,
      forecast_project_id: forecast_project.id,
      hourly_cost: hourly_cost,
      hours: hours,
      studio_id: studio_id,
      effective_date: @effective_date,
      needs_review: needs_review,
      created_at: DateTime.now,
      updated_at: DateTime.now
    }
  end

  def forecast_person_studio_id(forecast_person)
    return 0 if forecast_person.nil?

    @studios.each do |studio|
      if forecast_person.roles.include?(studio.name)
        return studio.id
      end
    end

    return 0
  end

  def forecast_person_hourly_cost(forecast_person, forecast_project)
    return 0 if forecast_person.nil?

    if forecast_person.admin_user.present?
      employee_hourly_cost(forecast_person, forecast_project)
    else
      subcontractor_hourly_cost(forecast_person, forecast_project)
    end
  end

  def employee_hourly_cost(forecast_person, forecast_project)
    admin_user = forecast_person.admin_user
    cost = admin_user.approximate_cost_per_sellable_hour_before_studio_expenses_on_date(@effective_date)

    if cost.nil?
      return 0
    end

    cost.round(2)
  end

  def subcontractor_hourly_cost(forecast_person, forecast_project)
    if forecast_project.notes.nil?
      return 0
    end

    # It's possible to record overrides to a particular individual's
    # (or contractor's) hourly rates in Harvest Forecast by adding a note
    # to the Forecast project in the form:
    # "contractor-name@contractor-domain.com:150p/h"
    regexp = /^([^:]+):\$?([0-9\.]+)p\/h/
    matches = forecast_project.notes.scan(regexp)

    match = matches.find do |match|
      match[0] == forecast_person.email
    end

    if match.present?
      match[1].to_f
    else
      0
    end
  end

  def needs_review?(forecast_person, studio_id, hourly_cost)
    if forecast_person.admin_user.present?
      if studio_id == 0
        return true
      end
    end

    hourly_cost == 0
  end
end
