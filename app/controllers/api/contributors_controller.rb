class Api::ContributorsController < ApiController
  before_action :check_private_api_key!

  def index
    fp_ids = ForecastPerson.where("lower(email) = ?", params[:email].to_s.strip.downcase).select(:forecast_id)
    render json: Contributor.where(forecast_person_id: fp_ids).map { |c|
      { id: c.id, email: c.forecast_person&.email, name: c.display_name }
    }
  end
end
