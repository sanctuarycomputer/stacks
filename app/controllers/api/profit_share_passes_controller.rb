class Api::ProfitSharePassesController < ActionController::Base
  def index
    result = ProfitSharePass.where.not(snapshot: nil)
    render json: Api::ProfitSharePassSerializer.new(result)
  end
end