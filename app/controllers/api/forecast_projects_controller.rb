class Api::ForecastProjectsController < ApiController
  skip_before_action :verify_authenticity_token
  before_action :check_private_api_key!

  def create
    tags = Array(params[:rates]).map { |r| Stacks::Forecast.rate_tag(r) }
    project = Stacks::Forecast.new.create_project(
      client_id: params.require(:client_id), name: params.require(:name),
      code: params.require(:code), tags: tags, notes: params[:notes].to_s,
    )
    render json: project_json(project)
  end

  def add_rate
    project = Stacks::Forecast.new.add_project_rate!(params[:forecast_id].to_i, params.require(:rate))
    render json: project_json(project)
  end

  def remove_rate
    project = Stacks::Forecast.new.remove_project_rate!(params[:forecast_id].to_i, params[:rate])
    render json: project_json(project)
  end

  private

  def project_json(p)
    { forecast_id: p["id"], name: p["name"], code: p["code"], client_id: p["client_id"],
      tags: p["tags"], rates: Array(p["tags"]).select { |t| t.to_s.end_with?("p/h") }.map(&:to_f) }
  end
end
