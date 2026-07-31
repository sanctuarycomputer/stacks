class Api::ProjectTrackersController < ApiController
  skip_before_action :verify_authenticity_token
  before_action :check_private_api_key!

  def index
    trackers = ProjectTracker.all
    if params[:client].present?
      client_ids = ForecastClient.where("lower(name) = ?", params[:client].strip.downcase).select(:forecast_id)
      fp_ids = ForecastProject.where(client_id: client_ids).select(:forecast_id)
      trackers = trackers.where(id: ProjectTrackerForecastProject.where(forecast_project_id: fp_ids).select(:project_tracker_id))
    end
    trackers = trackers.where("lower(name) = ?", params[:name].strip.downcase) if params[:name].present?
    render json: trackers.map { |t| tracker_json(t) }
  end

  def create
    tracker, warnings = ProjectTracker.provision!(
      name: params.require(:name), msa_url: params[:msa_url], sow_url: params[:sow_url],
      budget_low_end: params[:budget_low_end], budget_high_end: params[:budget_high_end],
    )
    render json: tracker_json(tracker).merge(warnings: warnings)
  end

  private

  def tracker_json(t)
    { id: t.id, name: t.name, client: t.derived_client&.name,
      workstreams: t.project_tracker_forecast_projects.map { |ws|
        fp = ws.forecast_project
        { id: ws.id, name: fp&.name, code: fp&.code,
          rates: Array(fp&.tags).select { |x| x.to_s.end_with?("p/h") }.map(&:to_f) }
      } }
  end
end
