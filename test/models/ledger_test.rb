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

class LedgerEnsureAllTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
  end

  test "creates a Ledger for every (enterprise, contributor) pair" do
    e1 = Enterprise.find_or_create_by!(name: "EA-1-#{SecureRandom.hex(2)}")
    e2 = Enterprise.find_or_create_by!(name: "EA-2-#{SecureRandom.hex(2)}")
    fp1 = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "ea1#{SecureRandom.hex(2)}@x.com", data: {})
    fp2 = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "ea2#{SecureRandom.hex(2)}@x.com", data: {})
    c1 = Contributor.create!(forecast_person: fp1)
    c2 = Contributor.create!(forecast_person: fp2)

    before = Ledger.count
    Ledger.ensure_all!
    after = Ledger.count

    # Each contributor x enterprise pair should now have a Ledger row.
    [c1, c2].each do |c|
      [e1, e2].each do |e|
        assert Ledger.exists?(contributor: c, enterprise: e),
          "expected a Ledger for contributor=#{c.id}, enterprise=#{e.id}"
      end
    end
    assert after > before, "expected at least one new Ledger to be created"
  end

  test "is idempotent — second call inserts nothing" do
    Ledger.ensure_all!
    inserted = Ledger.ensure_all!
    assert_equal 0, inserted
  end

  test "respects the (enterprise, contributor) uniqueness constraint" do
    e = Enterprise.find_or_create_by!(name: "EA-Uniq-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "uniq#{SecureRandom.hex(2)}@x.com", data: {})
    c = Contributor.create!(forecast_person: fp)
    Ledger.create!(enterprise: e, contributor: c)
    assert_nothing_raised { Ledger.ensure_all! }
    # Only one Ledger for this pair after ensure_all!.
    assert_equal 1, Ledger.where(enterprise: e, contributor: c).count
  end
end
