class Api::ProfitSharePassesController < ActionController::Base
  def index
    result = ProfitSharePass.all
    render json: Api::ProfitSharePassSerializer.new(result)
  end
end