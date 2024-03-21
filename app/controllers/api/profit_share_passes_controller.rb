class Api::ProfitSharePassesController < ActionController::Base
  def index
    result = ProfitSharePass.all
    render json: result, each_serializer: Api::ProfitSharePassSerializer
  end
end