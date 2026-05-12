require "test_helper"

class EnterpriseForecastClientTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: Enterprise::SANCTUARY_NAME)
    @forecast_client = ForecastClient.create!(forecast_id: 999_003, name: "Test Client")
  end

  test "a forecast client can only be linked to one enterprise" do
    EnterpriseForecastClient.create!(enterprise: @enterprise, forecast_client: @forecast_client)
    g3d = Enterprise.create!(name: "Garden3D LLC")
    assert_raises(ActiveRecord::RecordNotUnique) do
      EnterpriseForecastClient.create!(enterprise: g3d, forecast_client: @forecast_client)
    end
  end
end
