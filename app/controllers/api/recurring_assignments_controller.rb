class Api::RecurringAssignmentsController < ApiController
  skip_before_action :verify_authenticity_token
  before_action :check_private_api_key!

  def create
    contributor = Contributor.find(params.require(:contributor_id))
    workstream = ProjectTrackerForecastProject.find(params.require(:workstream_id))
    ra = RecurringAssignment.new(
      forecast_person_id: contributor.forecast_person_id,
      forecast_project_id: workstream.forecast_project_id,
      weekdays: (params[:weekdays].presence || [1, 2, 3, 4, 5]).map(&:to_i),
      starts_on: params[:starts_on].presence || Date.today,
      ends_on: params[:ends_on].presence,
      notes: params[:notes].to_s,
      active_on_days_off: ActiveModel::Type::Boolean.new.cast(params[:active_on_days_off]) || false,
    )
    ra.allocation_in_hours = params[:allocation_hours].presence || 8
    ra.save!
    render json: {
      id: ra.id, contributor_id: contributor.id, workstream_id: workstream.id,
      allocation_hours: ra.allocation_in_hours, weekdays: ra.weekdays,
      starts_on: ra.starts_on, ends_on: ra.ends_on,
    }
  end
end
