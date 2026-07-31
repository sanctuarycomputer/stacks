class Api::RecurringAssignmentsController < ApiController
  skip_before_action :verify_authenticity_token
  before_action :check_private_api_key!

  def create
    ra = RecurringAssignment.new(
      forecast_person_id: params.require(:forecast_person_id),
      forecast_project_id: params.require(:forecast_project_id),
      weekdays: (params[:weekdays].presence || [1, 2, 3, 4, 5]).map(&:to_i),
      starts_on: params[:starts_on].presence || Date.today,
      ends_on: params[:ends_on].presence,
      notes: params[:notes].to_s,
      active_on_days_off: ActiveModel::Type::Boolean.new.cast(params[:active_on_days_off]) || false,
    )
    ra.allocation_in_hours = params[:allocation_hours].presence || 8
    ra.save!
    render json: recurring_json(ra)
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue => e
    Rails.logger.warn("[Api::RecurringAssignments] #{e.class}: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def recurring_json(ra)
    { id: ra.id, forecast_person_id: ra.forecast_person_id, forecast_project_id: ra.forecast_project_id,
      allocation: ra.allocation, allocation_hours: ra.allocation_in_hours, weekdays: ra.weekdays,
      starts_on: ra.starts_on, ends_on: ra.ends_on }
  end
end
