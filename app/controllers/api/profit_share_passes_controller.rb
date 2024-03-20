class Api::ProfitSharePassesController < ActionController::Base
  def index
    profit_share_passes = ProfitSharePass.all
    result = profit_share_passes.map{|p| p.as_json.merge({"total_psu_issued"=> p.total_psu_issued}) }

    render json: result
  end
end