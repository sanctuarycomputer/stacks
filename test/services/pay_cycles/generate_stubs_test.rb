require "test_helper"

class PayCycles::GenerateStubsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "GenStubs-#{SecureRandom.hex(2)}")
    @cycle = PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 31))
  end

  test "considers only assignments on internal forecast clients of this enterprise" do
    # Internal client (name is in ForecastClient::INTERNAL_CLIENTS) mapped to THIS enterprise
    internal_client = ForecastClient.create!(forecast_id: 88_001, name: "garden3d")
    EnterpriseForecastClient.create!(enterprise: @enterprise, forecast_client_id: internal_client.forecast_id)
    internal_project = ForecastProject.create!(forecast_id: 88_001, client_id: internal_client.forecast_id, name: "Internal proj", tags: ["100p/h"])

    # External client (name not in INTERNAL_CLIENTS) on this enterprise — should be ignored
    external_client = ForecastClient.create!(forecast_id: 88_002, name: "Acme Corp")
    EnterpriseForecastClient.create!(enterprise: @enterprise, forecast_client_id: external_client.forecast_id)
    external_project = ForecastProject.create!(forecast_id: 88_002, client_id: external_client.forecast_id, name: "Acme proj", tags: ["100p/h"])

    fp = ForecastPerson.create!(forecast_id: 88_001, email: "gen1@example.com")

    ForecastAssignment.create!(forecast_id: 88_001, person_id: fp.forecast_id, project_id: internal_project.forecast_id, start_date: @cycle.starts_at, end_date: @cycle.ends_at, allocation: 8 * 60 * 60)
    ForecastAssignment.create!(forecast_id: 88_002, person_id: fp.forecast_id, project_id: external_project.forecast_id, start_date: @cycle.starts_at, end_date: @cycle.ends_at, allocation: 8 * 60 * 60)

    qualifying = PayCycles::GenerateStubs.new(@cycle).qualifying_assignments
    assert_equal 1, qualifying.size
    assert_equal internal_project.forecast_id, qualifying.first.project_id
  end

  test "resolve_rate uses per-email override when present" do
    client = ForecastClient.create!(forecast_id: rand(1..1000000), name: "Test Client")
    project = ForecastProject.create!(forecast_id: rand(1000000..2000000), client_id: client.forecast_id, name: "Test Project", tags: ["100p/h"], notes: "alice@example.com:120p/h")
    rate = PayCycles::GenerateStubs.new(@cycle).resolve_rate(project, "alice@example.com")
    assert_equal 120.0, rate
  end

  test "resolve_rate falls back to project's hourly_rate" do
    client = ForecastClient.create!(forecast_id: rand(1..1000000), name: "Test Client")
    project = ForecastProject.create!(forecast_id: rand(1000000..2000000), client_id: client.forecast_id, name: "Test Project", tags: ["75p/h"])
    rate = PayCycles::GenerateStubs.new(@cycle).resolve_rate(project, "bob@example.com")
    assert_equal 75.0, rate
  end

  test "resolve_rate returns default system rate when no override and no explicit tags" do
    client = ForecastClient.create!(forecast_id: rand(1..1000000), name: "Test Client")
    project = ForecastProject.create!(forecast_id: rand(1000000..2000000), client_id: client.forecast_id, name: "Test Project", tags: [])
    rate = PayCycles::GenerateStubs.new(@cycle).resolve_rate(project, "bob@example.com")
    # ForecastProject#hourly_rate defaults to System.instance.default_hourly_rate (175)
    assert_equal 175.0, rate
  end

  test "salaried_skip? true when contributor's admin_user has a non-variable_hours full-time period overlapping cycle end" do
    email = "salary#{rand(1000000)}@example.com"
    fp = ForecastPerson.create!(forecast_id: rand(1..10000), email: email, data: {})
    au = AdminUser.create!(email: email, password: "password123", password_confirmation: "password123")
    FullTimePeriod.create!(admin_user: au, started_at: Date.new(2025, 1, 1), ended_at: Date.new(2027, 1, 1), contributor_type: :five_day)
    skip = PayCycles::GenerateStubs.new(@cycle).salaried_skip?(fp)
    assert skip
  end

  test "salaried_skip? false when contributor has no full-time period (pure contractor)" do
    email = "contractor#{rand(1000000)}@example.com"
    fp = ForecastPerson.create!(forecast_id: rand(1..10000), email: email, data: {})
    au = AdminUser.create!(email: email, password: "password123", password_confirmation: "password123")
    refute PayCycles::GenerateStubs.new(@cycle).salaried_skip?(fp)
  end

  test "salaried_skip? false when variable_hours at cycle end" do
    email = "variable#{rand(1000000)}@example.com"
    fp = ForecastPerson.create!(forecast_id: rand(1..10000), email: email, data: {})
    au = AdminUser.create!(email: email, password: "password123", password_confirmation: "password123")
    FullTimePeriod.create!(admin_user: au, started_at: Date.new(2025, 1, 1), ended_at: Date.new(2027, 1, 1), contributor_type: :variable_hours)
    refute PayCycles::GenerateStubs.new(@cycle).salaried_skip?(fp)
  end
end
