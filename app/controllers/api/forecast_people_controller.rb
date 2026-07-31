class Api::ForecastPeopleController < ApiController
  before_action :check_private_api_key!

  def index
    people = ForecastPerson.where("lower(email) = ?", params[:email].to_s.strip.downcase)
    render json: people.map { |p| { forecast_id: p.forecast_id, email: p.email, name: p.name } }
  end
end
