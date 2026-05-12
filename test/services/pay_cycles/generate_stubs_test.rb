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

  test "call creates one stub per contributor with itemized blueprint" do
    setup_one_assignment(hours_per_day: 8)
    PayCycles::GenerateStubs.call(@cycle)
    assert_equal 1, @cycle.pay_stubs.count
    stub = @cycle.pay_stubs.first
    assert_equal 1, stub.blueprint["lines"].size
    line = stub.blueprint["lines"].first
    assert_equal @internal_project.forecast_id, line["forecast_project"]
    assert line["hours"] > 0
    assert_equal 100.0, line["rate"]
    assert_in_delta line["hours"] * 100.0, stub.amount.to_f, 0.01
  end

  test "call pro-rates assignments that cross cycle boundary" do
    # Twice-monthly cycle 1..15
    @cycle.update!(ends_at: Date.new(2026, 5, 15))
    setup_one_assignment(start_date: Date.new(2026, 5, 10), end_date: Date.new(2026, 5, 20), hours_per_day: 8)
    PayCycles::GenerateStubs.call(@cycle)
    stub = @cycle.pay_stubs.first
    # Days 10..15 = 6 days × 8h = 48 hours in this half
    assert_equal 48.0, stub.blueprint["lines"].first["hours"]
  end

  test "call skips salaried contributors" do
    setup_one_assignment(hours_per_day: 8)
    FullTimePeriod.create!(admin_user: @assignment_admin_user, started_at: Date.new(2025, 1, 1), ended_at: Date.new(2027, 1, 1), contributor_type: :five_day)
    PayCycles::GenerateStubs.call(@cycle)
    assert_equal 0, @cycle.pay_stubs.count
  end

  test "call hard-fails when a qualifying assignment has no resolvable rate" do
    setup_one_assignment(hours_per_day: 8, project_tags: [])  # no XXp/h tag → has_no_explicit_hourly_rate? = true
    assert_raises(PayCycles::GenerateStubs::MissingRateError) do
      PayCycles::GenerateStubs.call(@cycle)
    end
  end

  test "call preserves accepted_at when re-running with unchanged amount" do
    setup_one_assignment(hours_per_day: 8)
    PayCycles::GenerateStubs.call(@cycle)
    stub = @cycle.pay_stubs.first
    stub.update!(accepted_at: DateTime.now, accepted_by: @admin)
    original_accepted_at = stub.accepted_at
    PayCycles::GenerateStubs.call(@cycle)
    stub.reload
    assert_equal original_accepted_at.to_i, stub.accepted_at.to_i
    assert_equal @admin.id, stub.accepted_by_id
  end

  test "call resets accepted_at when amount changes on re-run" do
    setup_one_assignment(hours_per_day: 8)
    PayCycles::GenerateStubs.call(@cycle)
    stub = @cycle.pay_stubs.first
    stub.update!(accepted_at: DateTime.now, accepted_by: @admin)
    @assignment.update!(allocation: 4 * 60 * 60)   # halve daily allocation
    PayCycles::GenerateStubs.call(@cycle)
    stub.reload
    assert_nil stub.accepted_at
    assert_nil stub.accepted_by_id
  end

  test "call soft-deletes a stub whose contributor no longer has qualifying hours" do
    setup_one_assignment(hours_per_day: 8)
    PayCycles::GenerateStubs.call(@cycle)
    stub = @cycle.pay_stubs.first
    @assignment.update!(start_date: @cycle.starts_at - 5.days, end_date: @cycle.starts_at - 1.day)
    PayCycles::GenerateStubs.call(@cycle)
    stub.reload
    assert stub.deleted_at.present?
  end

  test "call raises when an accepted stub's contributor loses qualifying hours" do
    setup_one_assignment(hours_per_day: 8)
    PayCycles::GenerateStubs.call(@cycle)
    stub = @cycle.pay_stubs.first
    stub.update!(accepted_at: DateTime.now, accepted_by: @admin)
    @assignment.update!(start_date: @cycle.starts_at - 5.days, end_date: @cycle.starts_at - 1.day)
    assert_raises(PayCycles::GenerateStubs::AcceptedStubMissingHoursError) do
      PayCycles::GenerateStubs.call(@cycle)
    end
  end

  test "call does not write a stub for $0 amount" do
    setup_one_assignment(hours_per_day: 0, allocation_seconds: 0)
    PayCycles::GenerateStubs.call(@cycle)
    assert_equal 0, @cycle.pay_stubs.count
  end

  private

  # Helper to seed a single qualifying assignment for the cycle.
  # - Internal client uses a name from ForecastClient::INTERNAL_CLIENTS (so is_internal? returns true).
  # - Project tags default to ["100p/h"]; pass empty array to test no-rate.
  # - allocation_seconds: pass 0 for $0 stub test.
  def setup_one_assignment(start_date: nil, end_date: nil, hours_per_day: 8, project_tags: ["100p/h"], allocation_seconds: nil)
    @internal_client ||= ForecastClient.create!(forecast_id: SecureRandom.hex(8), name: "garden3d")
    EnterpriseForecastClient.find_or_create_by!(enterprise: @enterprise, forecast_client_id: @internal_client.forecast_id)
    @internal_project ||= ForecastProject.create!(forecast_id: SecureRandom.hex(8), client_id: @internal_client.forecast_id, name: "P #{SecureRandom.hex(2)}", tags: project_tags)
    @assignment_fp ||= ForecastPerson.create!(forecast_id: SecureRandom.hex(8), email: "asg#{SecureRandom.hex(3)}@example.com", data: {})
    @assignment_admin_user ||= AdminUser.create!(email: @assignment_fp.email, password: "password123", password_confirmation: "password123")
    @assignment_contributor ||= Contributor.find_or_create_by!(forecast_person: @assignment_fp)
    @admin ||= AdminUser.create!(email: "approver#{SecureRandom.hex(3)}@example.com", password: "password123", password_confirmation: "password123")
    allocation = allocation_seconds.nil? ? hours_per_day * 60 * 60 : allocation_seconds
    @assignment = ForecastAssignment.create!(
      forecast_id: SecureRandom.hex(8),
      person_id: @assignment_fp.forecast_id,
      project_id: @internal_project.forecast_id,
      start_date: start_date || @cycle.starts_at,
      end_date: end_date || @cycle.ends_at,
      allocation: allocation,
    )
  end
end
