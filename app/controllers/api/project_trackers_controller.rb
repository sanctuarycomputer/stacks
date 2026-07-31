class Api::ProjectTrackersController < ApiController
  skip_before_action :verify_authenticity_token
  before_action :check_private_api_key!

  def create
    tracker, warnings = ProjectTracker.provision!(
      name: params.require(:name),
      forecast_project_ids: Array(params[:forecast_project_ids]).map(&:to_i),
      msa_url: params[:msa_url], sow_url: params[:sow_url],
      budget_low_end: params[:budget_low_end], budget_high_end: params[:budget_high_end],
    )
    render json: {
      id: tracker.id, name: tracker.name,
      forecast_project_ids: tracker.forecast_projects.map(&:forecast_id),
      link_ids: tracker.project_tracker_links.map(&:id), warnings: warnings,
    }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActionController::ParameterMissing, ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue => e
    Rails.logger.warn("[Api::ProjectTrackers] #{e.class}: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
    render json: { error: "Provisioning call failed; the error was logged." }, status: :unprocessable_entity
  end
end
