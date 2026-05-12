require "test_helper"

class LedgerTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: Enterprise::SANCTUARY_NAME)
    fp = ForecastPerson.create!(forecast_id: 991_001, email: "test@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
  end

  test "belongs to enterprise and contributor" do
    ledger = Ledger.create!(enterprise: @enterprise, contributor: @contributor)
    assert_equal @enterprise, ledger.enterprise
    assert_equal @contributor, ledger.contributor
  end

  test "(enterprise, contributor) is unique" do
    Ledger.create!(enterprise: @enterprise, contributor: @contributor)
    assert_raises(ActiveRecord::RecordInvalid) do
      Ledger.create!(enterprise: @enterprise, contributor: @contributor)
    end
  end

  test ".find_or_create_for finds existing or creates new" do
    ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    assert ledger.persisted?
    same = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    assert_equal ledger, same
  end
end

class LedgerWithPayStubsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "LedgerStubs-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: 998_001, email: "lstest@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.create!(enterprise: @enterprise, contributor: @contributor)
    @cycle = PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 31))
    @admin = AdminUser.create!(email: "lsadm#{SecureRandom.hex(2)}@example.com", password: "password123", password_confirmation: "password123")
  end

  test "balance counts payable pay stubs" do
    blueprint = { "lines" => [{ "amount" => 100.0, "hours" => 1, "rate" => 100, "forecast_project" => "x", "description" => "x" }] }
    PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 100, blueprint: blueprint, accepted_at: DateTime.now, accepted_by: @admin)
    assert_equal 100, @ledger.balance.to_f
    assert_equal 0, @ledger.unsettled.to_f
  end

  test "unsettled counts un-payable pay stubs" do
    blueprint = { "lines" => [{ "amount" => 100.0, "hours" => 1, "rate" => 100, "forecast_project" => "x", "description" => "x" }] }
    PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 100, blueprint: blueprint)  # not accepted
    assert_equal 0, @ledger.balance.to_f
    assert_equal 100, @ledger.unsettled.to_f
  end

  test "all_items_with_deleted includes soft-deleted pay stubs" do
    blueprint = { "lines" => [{ "amount" => 100.0, "hours" => 1, "rate" => 100, "forecast_project" => "x", "description" => "x" }] }
    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 100, blueprint: blueprint)
    stub.destroy
    grouped = @ledger.items_grouped_by_month
    assert_includes grouped[:all].map(&:id), stub.id
  end
end
