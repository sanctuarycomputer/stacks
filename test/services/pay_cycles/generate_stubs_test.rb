require "test_helper"

class PayCycles::GenerateStubsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "GenStubs-#{SecureRandom.hex(2)}")
    @cycle = PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 31))
  end

  test "considers only assignments on internal forecast clients (mapped to this enterprise via enterprise_forecast_clients)" do
    # Internal: mapped to THIS enterprise via the join
    internal_client = ForecastClient.create!(forecast_id: 88_001, name: "Garden Internal")
    EnterpriseForecastClient.create!(enterprise: @enterprise, forecast_client_id: internal_client.forecast_id)
    internal_project = ForecastProject.create!(forecast_id: 88_001, client_id: internal_client.forecast_id, name: "Internal proj", tags: ["100p/h"])

    # External: NOT mapped to any enterprise_forecast_clients row — should be ignored
    external_client = ForecastClient.create!(forecast_id: 88_002, name: "Acme Corp")
    external_project = ForecastProject.create!(forecast_id: 88_002, client_id: external_client.forecast_id, name: "Acme proj", tags: ["100p/h"])

    fp = ForecastPerson.create!(forecast_id: 88_001, email: "gen1@example.com")

    ForecastAssignment.create!(forecast_id: 88_001, person_id: fp.forecast_id, project_id: internal_project.forecast_id, start_date: @cycle.starts_at, end_date: @cycle.ends_at, allocation: 8 * 60 * 60)
    ForecastAssignment.create!(forecast_id: 88_002, person_id: fp.forecast_id, project_id: external_project.forecast_id, start_date: @cycle.starts_at, end_date: @cycle.ends_at, allocation: 8 * 60 * 60)

    qualifying = PayCycles::GenerateStubs.new(@cycle).qualifying_assignments
    assert_equal 1, qualifying.size
    assert_equal internal_project.forecast_id, qualifying.first.project_id
  end

  test "ForecastClient#is_internal? is true iff mapped to an enterprise" do
    mapped = ForecastClient.create!(forecast_id: 89_001, name: "Mapped-#{SecureRandom.hex(2)}")
    EnterpriseForecastClient.create!(enterprise: @enterprise, forecast_client_id: mapped.forecast_id)
    assert mapped.reload.is_internal?

    unmapped = ForecastClient.create!(forecast_id: 89_002, name: "Unmapped-#{SecureRandom.hex(2)}")
    refute unmapped.is_internal?
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

  # Test 1: Multi-project contributor (multiple lines per stub)
  test "contributor with assignments on two internal projects gets one stub with two blueprint lines" do
    internal_client = ForecastClient.create!(forecast_id: safe_random_id, name: "garden3d")
    EnterpriseForecastClient.create!(enterprise: @enterprise, forecast_client_id: internal_client.forecast_id)

    project_a = ForecastProject.create!(forecast_id: safe_random_id, client_id: internal_client.forecast_id, name: "Proj A #{SecureRandom.hex(2)}", tags: ["100p/h"])
    project_b = ForecastProject.create!(forecast_id: safe_random_id, client_id: internal_client.forecast_id, name: "Proj B #{SecureRandom.hex(2)}", tags: ["80p/h"])

    fp = ForecastPerson.create!(forecast_id: safe_random_id, email: "multi#{SecureRandom.hex(3)}@example.com", data: {})
    admin = AdminUser.create!(email: "approver#{SecureRandom.hex(3)}@example.com", password: "password123", password_confirmation: "password123")

    # 4h/day on project A, 2h/day on project B across the full cycle
    ForecastAssignment.create!(forecast_id: safe_random_id, person_id: fp.forecast_id, project_id: project_a.forecast_id, start_date: @cycle.starts_at, end_date: @cycle.ends_at, allocation: 4 * 60 * 60)
    ForecastAssignment.create!(forecast_id: safe_random_id, person_id: fp.forecast_id, project_id: project_b.forecast_id, start_date: @cycle.starts_at, end_date: @cycle.ends_at, allocation: 2 * 60 * 60)

    PayCycles::GenerateStubs.call(@cycle)

    assert_equal 1, @cycle.pay_stubs.count
    stub = @cycle.pay_stubs.first
    lines = stub.blueprint["lines"]
    assert_equal 2, lines.size

    line_a = lines.find { |l| l["forecast_project"] == project_a.forecast_id }
    line_b = lines.find { |l| l["forecast_project"] == project_b.forecast_id }

    assert_not_nil line_a, "Expected a blueprint line for project A"
    assert_not_nil line_b, "Expected a blueprint line for project B"

    assert line_a["hours"] > 0
    assert_equal 100.0, line_a["rate"]
    assert_in_delta line_a["hours"] * 100.0, line_a["amount"], 0.01

    assert line_b["hours"] > 0
    assert_equal 80.0, line_b["rate"]
    assert_in_delta line_b["hours"] * 80.0, line_b["amount"], 0.01

    expected_total = (line_a["amount"] + line_b["amount"]).round(2)
    assert_in_delta expected_total, stub.amount.to_f, 0.01
  end

  # Test 2: Assignment exactly on cycle boundary (single-day at cycle start)
  test "assignment spanning exactly one day at cycle start contributes correct hours" do
    setup_one_assignment(
      start_date: @cycle.starts_at,
      end_date: @cycle.starts_at,
      hours_per_day: 8
    )
    PayCycles::GenerateStubs.call(@cycle)
    stub = @cycle.pay_stubs.first
    assert_not_nil stub
    line = stub.blueprint["lines"].first
    # allocation_during_range_in_hours: 1 day × 8h = 8h
    assert_equal 8.0, line["hours"]
  end

  # Test 3: Salaried contributor mid-stream (FullTimePeriod becomes five_day exactly at cycle.ends_at)
  test "contributor whose FullTimePeriod transitions to five_day at cycle ends_at is skipped" do
    email = "salarymid#{SecureRandom.hex(3)}@example.com"
    fp = ForecastPerson.create!(forecast_id: safe_random_id, email: email, data: {})
    au = AdminUser.create!(email: email, password: "password123", password_confirmation: "password123")
    # The period covers up to cycle.ends_at with five_day — salaried_skip? checks ends_at
    FullTimePeriod.create!(admin_user: au, started_at: @cycle.starts_at, ended_at: @cycle.ends_at + 1.year, contributor_type: :five_day)

    internal_client = ForecastClient.create!(forecast_id: safe_random_id, name: "Sanctuary Computer")
    EnterpriseForecastClient.create!(enterprise: @enterprise, forecast_client_id: internal_client.forecast_id)
    project = ForecastProject.create!(forecast_id: safe_random_id, client_id: internal_client.forecast_id, name: "SC Proj #{SecureRandom.hex(2)}", tags: ["100p/h"])
    ForecastAssignment.create!(forecast_id: safe_random_id, person_id: fp.forecast_id, project_id: project.forecast_id, start_date: @cycle.starts_at, end_date: @cycle.ends_at, allocation: 8 * 60 * 60)

    PayCycles::GenerateStubs.call(@cycle)
    assert_equal 0, @cycle.pay_stubs.count
  end

  # Test 4: Contributor with no admin_user at all (pure contractor)
  test "forecast_person with no admin_user is treated as non-salaried and gets a stub" do
    fp = ForecastPerson.create!(forecast_id: safe_random_id, email: "nouser#{SecureRandom.hex(3)}@example.com", data: {})
    # Deliberately do NOT create an AdminUser for this person

    internal_client = ForecastClient.create!(forecast_id: safe_random_id, name: "garden3d")
    EnterpriseForecastClient.create!(enterprise: @enterprise, forecast_client_id: internal_client.forecast_id)
    project = ForecastProject.create!(forecast_id: safe_random_id, client_id: internal_client.forecast_id, name: "Contractor Proj #{SecureRandom.hex(2)}", tags: ["90p/h"])
    ForecastAssignment.create!(forecast_id: safe_random_id, person_id: fp.forecast_id, project_id: project.forecast_id, start_date: @cycle.starts_at, end_date: @cycle.ends_at, allocation: 8 * 60 * 60)

    refute PayCycles::GenerateStubs.new(@cycle).salaried_skip?(fp)
    PayCycles::GenerateStubs.call(@cycle)
    assert_equal 1, @cycle.pay_stubs.count
  end

  # Test 5: Soft-deleted (hard-deleted) enterprise_forecast_client join row excludes assignment
  test "destroying enterprise_forecast_client row excludes that client's assignments from stubs" do
    internal_client = ForecastClient.create!(forecast_id: safe_random_id, name: "garden3d")
    efc = EnterpriseForecastClient.create!(enterprise: @enterprise, forecast_client_id: internal_client.forecast_id)
    project = ForecastProject.create!(forecast_id: safe_random_id, client_id: internal_client.forecast_id, name: "Dropped proj #{SecureRandom.hex(2)}", tags: ["100p/h"])

    fp = ForecastPerson.create!(forecast_id: safe_random_id, email: "dropped#{SecureRandom.hex(3)}@example.com", data: {})
    ForecastAssignment.create!(forecast_id: safe_random_id, person_id: fp.forecast_id, project_id: project.forecast_id, start_date: @cycle.starts_at, end_date: @cycle.ends_at, allocation: 8 * 60 * 60)

    # Destroy the join row — this is a hard delete since EnterpriseForecastClient is not paranoid
    efc.destroy!

    PayCycles::GenerateStubs.call(@cycle)
    assert_equal 0, @cycle.pay_stubs.count
  end

  # Test 6: Two enterprises, two pay cycles — each stub lands in the right enterprise ledger
  test "hours on Sanctuary client produce a Sanctuary stub; hours on garden3d client produce a garden3d stub" do
    # Enterprise A (Sanctuary-like)
    enterprise_a = @enterprise
    cycle_a = @cycle

    # Enterprise B
    enterprise_b = Enterprise.find_or_create_by!(name: "GenStubs-B-#{SecureRandom.hex(2)}")
    cycle_b = PayCycle.create!(enterprise: enterprise_b, starts_at: @cycle.starts_at, ends_at: @cycle.ends_at)

    # Internal client mapped to enterprise A
    client_a = ForecastClient.create!(forecast_id: safe_random_id, name: "Sanctuary Computer")
    EnterpriseForecastClient.create!(enterprise: enterprise_a, forecast_client_id: client_a.forecast_id)
    project_a = ForecastProject.create!(forecast_id: safe_random_id, client_id: client_a.forecast_id, name: "SC Proj #{SecureRandom.hex(2)}", tags: ["100p/h"])

    # Internal client mapped to enterprise B
    client_b = ForecastClient.create!(forecast_id: safe_random_id, name: "garden3d")
    EnterpriseForecastClient.create!(enterprise: enterprise_b, forecast_client_id: client_b.forecast_id)
    project_b = ForecastProject.create!(forecast_id: safe_random_id, client_id: client_b.forecast_id, name: "g3d Proj #{SecureRandom.hex(2)}", tags: ["80p/h"])

    # One contributor with hours on both
    fp = ForecastPerson.create!(forecast_id: safe_random_id, email: "biient#{SecureRandom.hex(3)}@example.com", data: {})
    ForecastAssignment.create!(forecast_id: safe_random_id, person_id: fp.forecast_id, project_id: project_a.forecast_id, start_date: @cycle.starts_at, end_date: @cycle.ends_at, allocation: 8 * 60 * 60)
    ForecastAssignment.create!(forecast_id: safe_random_id, person_id: fp.forecast_id, project_id: project_b.forecast_id, start_date: @cycle.starts_at, end_date: @cycle.ends_at, allocation: 4 * 60 * 60)

    PayCycles::GenerateStubs.call(cycle_a)
    PayCycles::GenerateStubs.call(cycle_b)

    stub_a = cycle_a.pay_stubs.first
    stub_b = cycle_b.pay_stubs.first

    assert_not_nil stub_a, "Expected a stub in enterprise A's cycle"
    assert_not_nil stub_b, "Expected a stub in enterprise B's cycle"

    assert_equal enterprise_a.id, stub_a.ledger.enterprise_id
    assert_equal enterprise_b.id, stub_b.ledger.enterprise_id

    # Each stub should reference only its own project
    assert_equal [project_a.forecast_id], stub_a.blueprint["lines"].map { |l| l["forecast_project"] }
    assert_equal [project_b.forecast_id], stub_b.blueprint["lines"].map { |l| l["forecast_project"] }
  end

  # Test 7: Cycle with zero qualifying assignments is a no-op
  test "call with no qualifying assignments creates no stubs and raises no errors" do
    # No internal clients mapped to this enterprise, no assignments at all
    assert_nothing_raised { PayCycles::GenerateStubs.call(@cycle) }
    assert_equal 0, @cycle.pay_stubs.count
  end

  # Test 8: Regen after un-accepting a stub — un-accepted state preserved when amount unchanged
  test "re-running after un-accepting a stub preserves the nil accepted_at when amount is unchanged" do
    setup_one_assignment(hours_per_day: 8)
    PayCycles::GenerateStubs.call(@cycle)
    stub = @cycle.pay_stubs.first
    admin = @admin

    # Accept then un-accept
    stub.update!(accepted_at: DateTime.now, accepted_by: admin)
    stub.update!(accepted_at: nil, accepted_by_id: nil)

    # Re-run with no Forecast changes
    PayCycles::GenerateStubs.call(@cycle)
    stub.reload
    assert_nil stub.accepted_at, "accepted_at should remain nil after re-run with unchanged amount"
  end

  # Test 9: Cycle :all_accepted — regen with same amount preserves accepted_at
  test "re-running when all stubs are accepted and amounts unchanged preserves accepted_at" do
    setup_one_assignment(hours_per_day: 8)
    PayCycles::GenerateStubs.call(@cycle)
    stub = @cycle.pay_stubs.first
    accepted_time = DateTime.new(2026, 5, 10, 12, 0, 0)
    stub.update!(accepted_at: accepted_time, accepted_by: @admin)

    PayCycles::GenerateStubs.call(@cycle)
    stub.reload
    assert_equal accepted_time.to_i, stub.accepted_at.to_i, "accepted_at should be preserved when amount is unchanged"
  end

  # Test 10: Cycle :all_accepted — regen with CHANGED amount resets affected stub's accepted_at
  test "re-running when all stubs are accepted but amount changed resets affected stub accepted_at" do
    # Two contributors: one whose amount will change, one whose won't
    internal_client = ForecastClient.create!(forecast_id: safe_random_id, name: "garden3d")
    EnterpriseForecastClient.create!(enterprise: @enterprise, forecast_client_id: internal_client.forecast_id)
    project = ForecastProject.create!(forecast_id: safe_random_id, client_id: internal_client.forecast_id, name: "Proj #{SecureRandom.hex(2)}", tags: ["100p/h"])

    fp1 = ForecastPerson.create!(forecast_id: safe_random_id, email: "stable#{SecureRandom.hex(3)}@example.com", data: {})
    fp2 = ForecastPerson.create!(forecast_id: safe_random_id, email: "change#{SecureRandom.hex(3)}@example.com", data: {})
    admin = AdminUser.create!(email: "apprv#{SecureRandom.hex(3)}@example.com", password: "password123", password_confirmation: "password123")

    asgn1 = ForecastAssignment.create!(forecast_id: safe_random_id, person_id: fp1.forecast_id, project_id: project.forecast_id, start_date: @cycle.starts_at, end_date: @cycle.ends_at, allocation: 8 * 60 * 60)
    asgn2 = ForecastAssignment.create!(forecast_id: safe_random_id, person_id: fp2.forecast_id, project_id: project.forecast_id, start_date: @cycle.starts_at, end_date: @cycle.ends_at, allocation: 8 * 60 * 60)

    PayCycles::GenerateStubs.call(@cycle)

    stub1 = @cycle.pay_stubs.joins(:ledger).where(ledgers: { contributor_id: Contributor.where(forecast_person_id: fp1.forecast_id).select(:id) }).first
    stub2 = @cycle.pay_stubs.joins(:ledger).where(ledgers: { contributor_id: Contributor.where(forecast_person_id: fp2.forecast_id).select(:id) }).first

    accepted_time = DateTime.new(2026, 5, 10, 12, 0, 0)
    stub1.update!(accepted_at: accepted_time, accepted_by: admin)
    stub2.update!(accepted_at: accepted_time, accepted_by: admin)

    # Change fp2's allocation — their amount will change
    asgn2.update!(allocation: 4 * 60 * 60)

    PayCycles::GenerateStubs.call(@cycle)

    stub1.reload
    stub2.reload

    # stub1's amount unchanged — accepted_at preserved
    assert_equal accepted_time.to_i, stub1.accepted_at.to_i, "unchanged stub should keep accepted_at"
    # stub2's amount changed — accepted_at reset
    assert_nil stub2.accepted_at, "changed stub should have accepted_at reset to nil"
  end

  # Test 11: Negative-allocation assignment should not produce a negative-amount stub.
  # Defensive: `allocation_during_range_in_seconds` clamps the day count but not the
  # per-day allocation, so a malformed Forecast row with `allocation: -N` can yield a
  # negative-amount line. `upsert_stubs` now guards `next if amount <= 0`, so no row
  # is persisted (and no negative QBO bill is ever attempted).
  test "negative allocation from malformed Forecast data does not produce a persisted stub" do
    internal_client = ForecastClient.create!(forecast_id: safe_random_id, name: "garden3d")
    EnterpriseForecastClient.create!(enterprise: @enterprise, forecast_client_id: internal_client.forecast_id)
    project = ForecastProject.create!(forecast_id: safe_random_id, client_id: internal_client.forecast_id, name: "Neg Proj #{SecureRandom.hex(2)}", tags: ["100p/h"])

    fp = ForecastPerson.create!(forecast_id: safe_random_id, email: "neg#{SecureRandom.hex(3)}@example.com", data: {})
    ForecastAssignment.create!(forecast_id: safe_random_id, person_id: fp.forecast_id, project_id: project.forecast_id, start_date: @cycle.starts_at, end_date: @cycle.ends_at, allocation: -100)

    PayCycles::GenerateStubs.call(@cycle)
    non_positive = @cycle.pay_stubs.select { |s| s.amount.to_f <= 0 }
    assert_empty non_positive, "No stub with non-positive amount should be persisted"
  end

  # Test 12: call is transactional — noted as future work if it requires invasive mocking
  # Skipped because constructing a mid-loop constraint failure without touching source files
  # would require monkey-patching ActiveRecord internals in the test.
  test "call is transactional — skipped pending non-invasive setup" do
    skip "Future test: requires invasive mocking to trigger mid-transaction save failure"
  end

  private

  def safe_random_id
    rand(1..2_000_000_000)
  end

  # Helper to seed a single qualifying assignment for the cycle.
  # - Internal client uses a name from ForecastClient::INTERNAL_CLIENTS (so is_internal? returns true).
  # - Project tags default to ["100p/h"]; pass empty array to test no-rate.
  # - allocation_seconds: pass 0 for $0 stub test.
  def setup_one_assignment(start_date: nil, end_date: nil, hours_per_day: 8, project_tags: ["100p/h"], allocation_seconds: nil)
    @internal_client ||= ForecastClient.create!(forecast_id: safe_random_id, name: "garden3d")
    EnterpriseForecastClient.find_or_create_by!(enterprise: @enterprise, forecast_client_id: @internal_client.forecast_id)
    @internal_project ||= ForecastProject.create!(forecast_id: safe_random_id, client_id: @internal_client.forecast_id, name: "P #{SecureRandom.hex(2)}", tags: project_tags)
    @assignment_fp ||= ForecastPerson.create!(forecast_id: safe_random_id, email: "asg#{SecureRandom.hex(3)}@example.com", data: {})
    @assignment_admin_user ||= AdminUser.create!(email: @assignment_fp.email, password: "password123", password_confirmation: "password123")
    @assignment_contributor ||= Contributor.find_or_create_by!(forecast_person: @assignment_fp)
    @admin ||= AdminUser.create!(email: "approver#{SecureRandom.hex(3)}@example.com", password: "password123", password_confirmation: "password123")
    allocation = allocation_seconds.nil? ? hours_per_day * 60 * 60 : allocation_seconds
    @assignment = ForecastAssignment.create!(
      forecast_id: safe_random_id,
      person_id: @assignment_fp.forecast_id,
      project_id: @internal_project.forecast_id,
      start_date: start_date || @cycle.starts_at,
      end_date: end_date || @cycle.ends_at,
      allocation: allocation,
    )
  end
end
