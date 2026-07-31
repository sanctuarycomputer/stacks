class Api::ForecastClientsController < ApiController
  before_action :check_private_api_key!

  def index
    clients = ForecastClient.where("lower(name) = ?", params[:name].to_s.strip.downcase)
    render json: clients.map { |c| { forecast_id: c.forecast_id, name: c.name } }
  end

  def projects
    projects = ForecastProject.where(client_id: params[:forecast_client_id])
    # ForecastProject has NO tracker association — reach it through the join model
    # (keyed on forecast_id), built once as a map to avoid N+1.
    tracker_by_fp = ProjectTrackerForecastProject
      .where(forecast_project_id: projects.map(&:forecast_id))
      .pluck(:forecast_project_id, :project_tracker_id).to_h
    render json: projects.map { |p|
      rates = Array(p.tags).select { |t| t.to_s.end_with?("p/h") }.map(&:to_f)
      { forecast_id: p.forecast_id, name: p.name, code: p.code, rates: rates,
        hourly_rate: p.hourly_rate, archived: p.archived,
        project_tracker_id: tracker_by_fp[p.forecast_id] }
    }
  end
end
