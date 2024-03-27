class Api::ProfitSharePassesController < ActionController::Base
  def index
    result = ProfitSharePass.finalized.order(:created_at)
    render json: result, each_serializer: Api::ProfitSharePassSerializer
  end
end