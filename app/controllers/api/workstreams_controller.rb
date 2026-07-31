class Api::WorkstreamsController < ApiController
  skip_before_action :verify_authenticity_token
  before_action :check_private_api_key!

  def create
    tracker = ProjectTracker.find(params[:project_tracker_id])
    ws = tracker.add_workstream!(
      name: params.require(:name), code: params.require(:code),
      rate: params[:rate], client_name: params[:client],
    )
    render json: workstream_json(ws)
  end

  def add_rate
    ws = ProjectTrackerForecastProject.find(params[:id])
    Stacks::Forecast.new.add_project_rate!(ws.forecast_project_id, params.require(:rate))
    render json: workstream_json(ws.reload)
  end

  def remove_rate
    ws = ProjectTrackerForecastProject.find(params[:id])
    Stacks::Forecast.new.remove_project_rate!(ws.forecast_project_id, params.require(:rate))
    render json: workstream_json(ws.reload)
  end

  private

  def workstream_json(ws)
    fp = ws.forecast_project
    { id: ws.id, project_tracker_id: ws.project_tracker_id, name: fp&.name, code: fp&.code,
      client: fp&.forecast_client&.name,
      rates: Array(fp&.tags).select { |x| x.to_s.end_with?("p/h") }.map(&:to_f) }
  end
end
