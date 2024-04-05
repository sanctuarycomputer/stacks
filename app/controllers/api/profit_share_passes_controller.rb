class Api::ProfitSharePassesController < ActionController::Base
  def index
    result = ProfitSharePass.where.not(snapshot: nil).order(:created_at)
    render json: result, each_serializer: Api::ProfitSharePassSerializer
  end
end