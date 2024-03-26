class Api::ProfitSharePassesController < ActionController::Base
  def index
    result = ProfitSharePass.where.not(snapshot: nil)
    render json: result, each_serializer: Api::ProfitSharePassSerializer
  end
end