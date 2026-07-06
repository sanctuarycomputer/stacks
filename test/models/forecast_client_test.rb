require "test_helper"

class ForecastClientTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    Enterprise.find_or_create_by!(name: Enterprise::SANCTUARY_NAME)
  end

  test "#billing_enterprise returns the linked enterprise when present" do
    g3d = Enterprise.create!(name: "Garden3D LLC")
    fc = ForecastClient.create!(forecast_id: 999_001, name: "Garden3D LLC")
    EnterpriseForecastClient.create!(enterprise: g3d, forecast_client: fc)
    assert_equal g3d, fc.reload.billing_enterprise
  end

  test "#billing_enterprise falls back to Enterprise.sanctuary when no link" do
    fc = ForecastClient.create!(forecast_id: 999_002, name: "Adidas")
    assert_equal Enterprise.sanctuary, fc.billing_enterprise
  end
end
