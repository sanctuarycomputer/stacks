class Stacks::ForecastPersonCostWindowSyncer
  HISTORICAL_SUBCONTRACTOR_RATES = {}


  def initialize(forecast_project:, forecast_person:, target_date:)
    @forecast_project = forecast_project
    @forecast_person = forecast_person
    @target_date = target_date
  end

  def sync!
    Rails.logger.info(
      "Syncing cost windows for Forecast project #{@forecast_project.forecast_id}, "\
      "person #{@forecast_person.email}, date #{@target_date}..."
    )

    max_end_date = @forecast_project.start_date || @target_date
    cost_windows = @forecast_person.forecast_person_cost_windows
    needs_new_cost_window = cost_windows.empty?

    cost_windows.each do |cost_window|
      if cost_window.end_date.present?
        max_end_date = [max_end_date, cost_window.end_date].min
        next
      end

      next if cost_window.forecast_project_id != @forecast_project.forecast_id
      next if cost_window.hourly_cost == hourly_cost

      max_end_date = @target_date - 1.day
      cost_window.update!(end_date: max_end_date)
      needs_new_cost_window = true
    end

    if needs_new_cost_window
      ForecastPersonCostWindow.create!({
        forecast_project: @forecast_project,
        forecast_person: @forecast_person,
        start_date: [@target_date, max_end_date + 1.day].min,
        end_date: nil,
        needs_review: hourly_cost == 0,
        hourly_cost: hourly_cost
      })
    end
  end

  private

  def hourly_cost
    @_hourly_cost ||= if @forecast_person.admin_user.present?
      employee_rate
    else
      subcontractor_rate
    end
  end

  def employee_rate
    admin_user = @forecast_person.admin_user
    cost = admin_user.approximate_cost_per_sellable_hour_before_studio_expenses_on_date(@target_date)

    if cost.nil?
      return 0
    end

    cost.round(2)
  end

  def subcontractor_rate
    if @forecast_project.notes.nil?
      return hardcoded_subcontractor_rate
    end

    # It's possible to record overrides to a particular individual's
    # (or contractor's) hourly rates in Harvest Forecast by adding a note
    # to the Forecast project in the form:
    # "contractor-name@contractor-domain.com: $XYZ.XX"
    # (The leading dollar sign on the hourly rate is optional.)
    regexp = /^([^:]+): ?\$([0-9\.]+)/
    matches = @forecast_project.notes.scan(regexp)

    match = matches.find do |match|
      match[0] == @forecast_person.email
    end

    if match.present?
      match[1].to_f
    else
      hardcoded_subcontractor_rate
    end
  end

  def hardcoded_subcontractor_rate
    HISTORICAL_SUBCONTRACTOR_RATES[@forecast_person.email] || 0
  end
end
